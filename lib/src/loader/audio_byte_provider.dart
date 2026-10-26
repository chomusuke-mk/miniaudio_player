import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../api/miniaudio_player.dart'
    show AssetBytesLoader, MiniaudioPlayerGlobalConfig;
import '../api/player_exception.dart';
import '../platform/fs_helper.dart';
import '../platform/http_helper.dart';

/// Response returned when opening an [AudioByteProvider] stream at a specific offset.
class AudioByteStreamResponse {
  /// Stream of raw container bytes starting at the requested offset.
  final Stream<Uint8List> stream;

  /// Total size of the underlying resource in bytes, or `-1` / `0` if unknown / live stream.
  final int totalBytes;

  /// Whether the underlying resource supports random-access byte offsets.
  final bool isSeekable;

  /// Whether the stream is an infinite or chunked live stream.
  final bool isLive;

  /// Optional MIME content-type header.
  final String? contentType;

  /// Optional protocol/header metadata (e.g., ICY station headers).
  final Map<String, String> metadata;

  const AudioByteStreamResponse({
    required this.stream,
    required this.totalBytes,
    required this.isSeekable,
    this.isLive = false,
    this.contentType,
    this.metadata = const {},
  });
}

/// Unified abstraction for providing encoded audio bytes from any source
/// (File, Memory, Asset, HTTP VOD, Live Stream, or user-defined custom sources).
abstract class AudioByteProvider {
  /// Diagnostic identifier or URI for this byte source.
  String get sourceId;

  /// Optional URI associated with this byte source.
  Uri? get uri => null;

  /// Whether this source represents an infinite or non-seekable live stream.
  bool get isLiveStream => false;

  /// Whether this source fetches data over a network connection.
  bool get isNetwork => false;

  /// Opens a sequential byte stream starting at [offset] (and optionally bounded by [length]).
  Future<AudioByteStreamResponse> open({int offset = 0, int? length});

  /// Reads a slice from the end of the resource (`[tailOffset .. tailOffset + length)`)
  /// without disturbing the main sequential stream, used for probing trailing metadata
  /// (ID3v1, APEv2, WAV LIST-INFO, Ogg final granule_pos, or MP4 trailing `moov` atoms).
  ///
  /// Returns `null` if the source does not support random-access tail probing.
  Future<Uint8List?> probeTail(int tailOffset, int length) async => null;

  /// Aborts any currently active read/network stream without permanently disposing
  /// underlying reusable resources (such as an owned kernel file descriptor `fd`).
  Future<void> abortActiveStream() async {}

  /// Closes any active file handles, descriptors, or network connections held by this provider.
  Future<void> close();
}

/// Provides audio bytes directly from an in-memory [Uint8List].
class MemoryByteProvider extends AudioByteProvider {
  final Uint8List _bytes;
  final String _label;
  final Uri? _uri;
  final String? contentType;

  MemoryByteProvider(
    this._bytes, {
    String label = 'memory://buffer',
    Uri? uri,
    this.contentType,
  })  : _label = label,
        _uri = uri;

  /// Direct read-only view of the underlying bytes.
  Uint8List get bytes => _bytes;

  @override
  String get sourceId => _label;

  @override
  Uri? get uri => _uri;

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    if (_bytes.isEmpty) {
      throw const MiniaudioPlayerException(
        'Cannot open empty byte buffer',
        errorCode: MapResult.errorInvalidArgs,
      );
    }
    final int start = offset.clamp(0, _bytes.length);
    final int end = length != null
        ? (start + length).clamp(start, _bytes.length)
        : _bytes.length;
    final slice = Uint8List.sublistView(_bytes, start, end);
    return AudioByteStreamResponse(
      stream: slice.isEmpty
          ? const Stream<Uint8List>.empty()
          : Stream<Uint8List>.value(slice),
      totalBytes: _bytes.length,
      isSeekable: true,
      isLive: false,
      contentType: contentType,
    );
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    if (tailOffset < 0 || tailOffset >= _bytes.length || length <= 0) {
      return null;
    }
    final int end = (tailOffset + length).clamp(tailOffset, _bytes.length);
    return Uint8List.sublistView(_bytes, tailOffset, end);
  }

  @override
  Future<void> close() async {}
}

/// Provides audio bytes from a local filesystem path.
class FileByteProvider extends AudioByteProvider {
  final String filePath;

  FileByteProvider(String path) : filePath = normalizeFileUriOrPath(path);

  /// Normalizes a `file://` URI or raw filesystem path (POSIX or Windows) into an OS path.
  static String normalizeFileUriOrPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';
    if (UriCapabilityResolver.isWindowsFilePath(trimmed)) {
      return trimmed;
    }
    if (trimmed.toLowerCase().startsWith('file://')) {
      String withoutScheme = trimmed.replaceFirst(
        RegExp(r'^file://(localhost)?', caseSensitive: false),
        '',
      );
      try {
        final decoded = Uri.decodeFull(withoutScheme);
        // Handle file:///C:/Users/... on any host OS
        if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(decoded)) {
          return decoded.substring(1);
        }
        if (UriCapabilityResolver.isWindowsFilePath(decoded)) {
          return decoded;
        }
      } catch (_) {}
      try {
        final uri = Uri.parse(trimmed);
        final filePath = uri.toFilePath();
        if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(filePath)) {
          return filePath.substring(1);
        }
        return filePath;
      } catch (_) {
        final decoded = Uri.decodeFull(withoutScheme);
        if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(decoded)) {
          return decoded.substring(1);
        }
        return decoded;
      }
    }
    return trimmed;
  }

  @override
  String get sourceId => filePath;

  @override
  Uri? get uri {
    if (filePath.isEmpty) return null;
    if (UriCapabilityResolver.isWindowsFilePath(filePath)) {
      return Uri.file(filePath, windows: true);
    }
    return Uri.file(filePath);
  }

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    if (!checkFileExists(filePath)) {
      throw MiniaudioPlayerException(
        'Audio file not found at path: $filePath',
        errorCode: MapResult.errorFileNotFound,
      );
    }
    final int totalBytes;
    try {
      totalBytes = await getFileLength(filePath);
    } catch (e) {
      throw MiniaudioPlayerException(
        'Failed to open audio file ($filePath): $e',
        errorCode: MapResult.errorDecodeFailed,
      );
    }
    if (totalBytes <= 0) {
      throw MiniaudioPlayerException(
        'Failed to open empty audio file ($filePath)',
        errorCode: MapResult.errorDecodeFailed,
      );
    }
    final int start = offset.clamp(0, totalBytes);
    final int? effectiveLength = length != null
        ? (start + length > totalBytes ? totalBytes - start : length)
        : null;

    return AudioByteStreamResponse(
      stream: openFileStream(filePath, offset: start, length: effectiveLength),
      totalBytes: totalBytes,
      isSeekable: true,
      isLive: false,
    );
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    if (tailOffset < 0 || length <= 0) return null;
    try {
      return await readFileRange(filePath, tailOffset, length);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> close() async {}
}

/// Provides audio bytes from a Flutter asset key or local asset bundle.
class AssetByteProvider extends AudioByteProvider {
  final String assetPath;
  final String? package;
  final AssetBytesLoader? loader;
  Uint8List? _cachedBytes;
  late final String _resolvedKey;

  AssetByteProvider(
    this.assetPath, {
    this.package,
    this.loader,
  }) {
    String cleanKey = assetPath.trim();
    String? effectivePackage = package;
    if (cleanKey.toLowerCase().startsWith('package:')) {
      final body = cleanKey.substring('package:'.length);
      final slashIdx = body.indexOf('/');
      if (slashIdx > 0) {
        effectivePackage ??= body.substring(0, slashIdx);
        cleanKey = body.substring(slashIdx + 1);
      }
    } else {
      cleanKey = cleanKey.replaceFirst(
        RegExp(r'^(flutter-)?asset(s)?:///?', caseSensitive: false),
        '',
      );
    }
    _resolvedKey = effectivePackage != null
        ? 'packages/$effectivePackage/$cleanKey'
        : cleanKey;
  }

  Future<Uint8List> _ensureLoaded() async {
    final existing = _cachedBytes;
    if (existing != null) return existing;

    Uint8List? bytes;
    final effectiveLoader = loader ?? MiniaudioPlayerGlobalConfig.assetLoader;
    if (effectiveLoader != null) {
      try {
        bytes = await effectiveLoader(_resolvedKey);
      } catch (e) {
        throw MiniaudioPlayerException(
          'Failed to load asset "$_resolvedKey": $e',
          errorCode: MapResult.errorFileNotFound,
        );
      }
    } else {
      final cleanKey = assetPath.replaceFirst(RegExp(r'^asset(s)?://'), '');
      final candidates = [
        _resolvedKey,
        cleanKey,
        'assets/$cleanKey',
        'example/assets/$cleanKey',
        'example/assets/music/$cleanKey',
      ];
      for (final candidate in candidates) {
        bytes = readBytesFromFile(candidate);
        if (bytes != null) break;
      }
    }

    if (bytes == null || bytes.isEmpty) {
      throw MiniaudioPlayerException(
        'Asset not found: "$_resolvedKey". Configure MiniaudioPlayerGlobalConfig.assetLoader for Flutter assets.',
        errorCode: MapResult.errorFileNotFound,
      );
    }
    _cachedBytes = bytes;
    return bytes;
  }

  @override
  String get sourceId => 'asset://$_resolvedKey';

  @override
  Uri? get uri => Uri.parse('asset://$_resolvedKey');

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    final bytes = await _ensureLoaded();
    final int start = offset.clamp(0, bytes.length);
    final int end = length != null
        ? (start + length).clamp(start, bytes.length)
        : bytes.length;
    final slice = Uint8List.sublistView(bytes, start, end);
    return AudioByteStreamResponse(
      stream: slice.isEmpty
          ? const Stream<Uint8List>.empty()
          : Stream<Uint8List>.value(slice),
      totalBytes: bytes.length,
      isSeekable: true,
      isLive: false,
    );
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    final bytes = await _ensureLoaded();
    if (tailOffset < 0 || tailOffset >= bytes.length || length <= 0) {
      return null;
    }
    final int end = (tailOffset + length).clamp(tailOffset, bytes.length);
    return Uint8List.sublistView(bytes, tailOffset, end);
  }

  @override
  Future<void> close() async {}
}

/// Provides audio bytes over HTTP/HTTPS with Range support, transient retry/backoff,
/// and ICY metadata demuxing.
class NetworkByteProvider extends AudioByteProvider {
  final Uri _uri;
  final Map<String, String>? headers;
  final void Function(Uint8List icyMetaBytes)? onIcyMetaBytes;
  bool _isLiveStream;
  final int maxRetries;

  void Function()? _activeAbort;
  int _connectionGeneration = 0;

  NetworkByteProvider(
    Uri uri, {
    this.headers,
    this.onIcyMetaBytes,
    bool isLiveStream = false,
    this.maxRetries = 5,
  })  : _uri = uri,
        _isLiveStream = isLiveStream;

  @override
  String get sourceId => _uri.toString();

  @override
  Uri? get uri => _uri;

  @override
  bool get isLiveStream => _isLiveStream;

  @override
  bool get isNetwork => true;

  Map<String, String> _buildRequestHeaders({int offset = 0, int? length}) {
    final reqHeaders = <String, String>{};
    if (headers != null) {
      reqHeaders.addAll(headers!);
    }
    if (!reqHeaders.keys.any((k) => k.toLowerCase() == 'icy-metadata')) {
      reqHeaders['Icy-MetaData'] = '1';
    }
    if (!_isLiveStream && (offset > 0 || length != null)) {
      if (length != null && length > 0) {
        reqHeaders['Range'] = 'bytes=$offset-${offset + length - 1}';
      } else {
        reqHeaders['Range'] = 'bytes=$offset-';
      }
    }
    return reqHeaders;
  }

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    _connectionGeneration++;
    final int gen = _connectionGeneration;
    _activeAbort?.call();
    _activeAbort = null;

    int openRetries = 0;
    while (true) {
      RawHttpResponse res;
      try {
        res = await sendHttpGetRequest(
          _uri,
          headers: _buildRequestHeaders(offset: offset, length: length),
        );
      } catch (e) {
        final errStr = e.toString();
        final isCors = errStr.contains('Failed to fetch') || errStr.contains('CORS');
        throw MiniaudioPlayerException(
          isCors
              ? 'Failed to connect to $_uri: CORS request blocked by browser policy. The remote server does not provide "Access-Control-Allow-Origin" headers.'
              : 'Failed to connect to $_uri: $e',
          errorCode: MapResult.errorFileNotFound,
        );
      }

      if (gen != _connectionGeneration) {
        res.abort();
        throw const MiniaudioPlayerException(
          'Network request superseded',
          errorCode: MapResult.errorGeneric,
        );
      }

      _activeAbort = res.abort;
      final statusCode = res.statusCode;

      if ((statusCode == 429 ||
              statusCode == 503 ||
              statusCode == 502 ||
              statusCode == 504) &&
          openRetries < maxRetries) {
        openRetries++;
        res.abort();
        final retryAfter =
            int.tryParse(res.headers['retry-after'] ?? '') ?? 2;
        await Future<void>.delayed(
          Duration(
            milliseconds: min(6000, max(1000, retryAfter * 1000 * openRetries)),
          ),
        );
        if (gen != _connectionGeneration) {
          throw const MiniaudioPlayerException(
            'Network request superseded',
            errorCode: MapResult.errorGeneric,
          );
        }
        continue;
      }

      if (statusCode >= 400) {
        res.abort();
        throw MiniaudioPlayerException(
          'HTTP $statusCode (${res.reasonPhrase}) while opening $_uri',
          errorCode: statusCode == 404
              ? MapResult.errorFileNotFound
              : (statusCode == 403 ? MapResult.errorAccessDenied : statusCode),
        );
      }

      int totalBytes = res.contentLength;
      bool isSeekable = res.headers['accept-ranges']?.toLowerCase() == 'bytes' ||
          (totalBytes > 0 && !_isLiveStream);

      final contentRange = res.headers['content-range'];
      if (statusCode == 206 && contentRange != null) {
        isSeekable = true;
        final slashIdx = contentRange.lastIndexOf('/');
        if (slashIdx != -1) {
          final totalStr = contentRange.substring(slashIdx + 1).trim();
          if (totalStr != '*') {
            totalBytes = int.tryParse(totalStr) ?? totalBytes;
          }
        }
      } else if (offset > 0 && statusCode == 200) {
        // Server returned 200 instead of 206: range requests are not supported.
        isSeekable = false;
      }

      final int icyMetaint =
          int.tryParse(res.headers['icy-metaint'] ?? '') ?? 0;

      final bool detectedLive = _isLiveStream ||
          totalBytes <= 0 ||
          icyMetaint > 0 ||
          res.headers.containsKey('icy-name') ||
          res.headers.containsKey('icy-br') ||
          res.headers['transfer-encoding']?.toLowerCase() == 'chunked';
      if (detectedLive) {
        _isLiveStream = true;
      }

      final Stream<Uint8List> demuxedStream = icyMetaint > 0
          ? res.stream.transform(_createIcyDemuxTransformer(icyMetaint))
          : res.stream;

      final meta = <String, String>{};
      for (final key in ['icy-name', 'icy-genre', 'icy-br']) {
        final v = res.headers[key];
        if (v != null && v.isNotEmpty) meta[key] = v;
      }

      return AudioByteStreamResponse(
        stream: demuxedStream,
        totalBytes: detectedLive ? -1 : totalBytes,
        isSeekable: !detectedLive && isSeekable,
        isLive: detectedLive,
        contentType: res.headers['content-type'],
        metadata: meta,
      );
    }
  }

  StreamTransformer<Uint8List, Uint8List> _createIcyDemuxTransformer(
    int icyMetaint,
  ) {
    int remainingAudio = icyMetaint;
    int remainingMeta = 0;
    bool readingLength = false;
    final metaBuilder = BytesBuilder(copy: false);

    return StreamTransformer<Uint8List, Uint8List>.fromHandlers(
      handleData: (chunk, sink) {
        int offset = 0;
        while (offset < chunk.length) {
          if (remainingAudio > 0) {
            final takeAudio = min(remainingAudio, chunk.length - offset);
            sink.add(Uint8List.sublistView(chunk, offset, offset + takeAudio));
            offset += takeAudio;
            remainingAudio -= takeAudio;
            if (remainingAudio == 0) {
              readingLength = true;
            }
          } else if (readingLength) {
            final l = chunk[offset++];
            readingLength = false;
            if (l > 0) {
              remainingMeta = l * 16;
              metaBuilder.clear();
            } else {
              remainingAudio = icyMetaint;
            }
          } else if (remainingMeta > 0) {
            final takeMeta = min(remainingMeta, chunk.length - offset);
            metaBuilder.add(
              Uint8List.sublistView(chunk, offset, offset + takeMeta),
            );
            offset += takeMeta;
            remainingMeta -= takeMeta;
            if (remainingMeta == 0) {
              final metaBytes = metaBuilder.takeBytes();
              onIcyMetaBytes?.call(metaBytes);
              remainingAudio = icyMetaint;
            }
          }
        }
      },
      handleDone: (sink) => sink.close(),
      handleError: (error, stackTrace, sink) =>
          sink.addError(error, stackTrace),
    );
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    if (_isLiveStream || tailOffset < 0 || length <= 0) return null;
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      RawHttpResponse? res;
      try {
        final probeHeaders = <String, String>{};
        if (headers != null) probeHeaders.addAll(headers!);
        probeHeaders['Range'] = 'bytes=$tailOffset-${tailOffset + length - 1}';
        res = await sendHttpGetRequest(_uri, headers: probeHeaders)
            .timeout(const Duration(seconds: 6));
        if (res.statusCode == 429 ||
            res.statusCode == 503 ||
            res.statusCode == 502 ||
            res.statusCode == 504) {
          final retryAfter =
              int.tryParse(res.headers['retry-after'] ?? '') ?? 2;
          res.abort();
          if (attempt < maxRetries) {
            await Future<void>.delayed(
              Duration(
                milliseconds: min(5000, max(1000, retryAfter * 1000 * (attempt + 1))),
              ),
            );
            continue;
          }
          return null;
        }
        if (res.statusCode != 206) {
          res.abort();
          return null;
        }
        final builder = BytesBuilder(copy: false);
        await for (final chunk
            in res.stream.timeout(const Duration(seconds: 6))) {
          builder.add(chunk);
          if (builder.length >= length) break;
        }
        res.abort();
        return builder.takeBytes();
      } catch (_) {
        res?.abort();
        if (attempt >= maxRetries) return null;
      }
    }
    return null;
  }

  @override
  Future<void> abortActiveStream() async => close();

  @override
  Future<void> close() async {
    _connectionGeneration++;
    _activeAbort?.call();
    _activeAbort = null;
  }
}

/// Convenience provider for continuous HTTP/ICY live streams.
class LiveStreamByteProvider extends NetworkByteProvider {
  LiveStreamByteProvider(
    super.uri, {
    super.headers,
    super.onIcyMetaBytes,
    super.maxRetries,
  }) : super(isLiveStream: true);
}

// ============================================================================
// Level 2: FdByteProvider & Capability Promotion Pipeline
// ============================================================================

/// Result of synchronous local path deduction from a `content://`, `fd://`, or custom URI.
class UriPathDeduction {
  /// Canonical local filesystem path deduced from the URI, if any.
  final String? canonicalPath;

  /// Ordered candidate local filesystem paths to probe for direct readability.
  final List<String> candidatePaths;

  /// True if the URI was rejected due to a directory traversal attempt (`/../` or `\..\`).
  final bool rejectedByPathTraversal;

  const UriPathDeduction({
    this.canonicalPath,
    this.candidatePaths = const [],
    this.rejectedByPathTraversal = false,
  });
}

/// Generalized URI normalization, security sanitization, and Capability Promotion
/// resolver implementing `URI_IMPLEMENTATION.md`.
class UriCapabilityResolver {
  const UriCapabilityResolver._();

  static final RegExp _windowsDrivePattern = RegExp(r'^[a-zA-Z]:[\\/]');
  static final RegExp _androidMntUserPattern =
      RegExp(r'^/mnt/user/\d+/emulated/(\d+)(/.*)?$');
  static final RegExp _androidMntRuntimePattern =
      RegExp(r'^/mnt/(?:runtime|pass_through)/[^/]+/emulated/(\d+)(/.*)?$');
  static final RegExp _androidDataMediaPattern =
      RegExp(r'^/data/media/(\d+)(/.*)?$');
  static final RegExp _fdSchemePattern =
      RegExp(r'^fd:///?(\d+)$|^fd:(\d+)$', caseSensitive: false);
  static final RegExp _procFdPathPattern = RegExp(
    r'^(?:file://(?:localhost)?)?/proc/(?:self|\d+)/fd/(\d+)$',
    caseSensitive: false,
  );
  static final RegExp _opaqueMediaDocPrefix = RegExp(
    r'^(?:audio|video|image|document|msf|msd|downloads)$',
    caseSensitive: false,
  );

  /// Precaución 4: Returns `true` if [input] is a Windows drive path (`C:\...` or `C:/...`)
  /// or UNC network share path (`\\server\share\...`).
  static bool isWindowsFilePath(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return false;
    return _windowsDrivePattern.hasMatch(trimmed) || trimmed.startsWith(r'\\');
  }

  /// Precaución 7: Returns `true` if [path] contains any directory traversal segments
  /// (`..`, `/../`, `\..\`, or null bytes).
  static bool hasPathTraversal(String path) {
    if (path.isEmpty) return false;
    if (path.contains('\x00')) return true;
    final normalizedSlashes = path.replaceAll('\\', '/');
    if (normalizedSlashes == '..' ||
        normalizedSlashes.startsWith('../') ||
        normalizedSlashes.endsWith('/..') ||
        normalizedSlashes.contains('/../')) {
      return true;
    }
    final segments = normalizedSlashes.split('/');
    return segments.any((s) => s == '..');
  }

  /// Precaución 7: Safely resolves [relativePath] inside [rootDir], rejecting any
  /// path traversal attempt (`..`) and verifying the normalized path remains strictly
  /// inside [rootDir].
  static String? resolveWithinRoot(String rootDir, String relativePath) {
    final cleanRoot = rootDir.trim();
    final cleanRel = relativePath.trim();
    if (cleanRoot.isEmpty || cleanRel.isEmpty) return null;
    if (hasPathTraversal(cleanRel) || hasPathTraversal(cleanRoot)) {
      return null;
    }

    final normRoot = cleanRoot
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+'), '/')
        .replaceAll(RegExp(r'/+$'), '');
    if (normRoot.isEmpty) return null;

    final rawSegments = cleanRel.replaceAll('\\', '/').split('/');
    final safeSegments = <String>[];
    for (final seg in rawSegments) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      safeSegments.add(seg);
    }
    if (safeSegments.isEmpty) return null;

    final joined = '$normRoot/${safeSegments.join('/')}';
    if (!joined.startsWith('$normRoot/')) {
      return null;
    }
    return joined;
  }

  /// Precaución 3: Rewrites Android internal FUSE / `sdcardfs` mount paths
  /// (`/mnt/user/<uid>/emulated/<id>/...` or `/data/media/<id>/...`) to their
  /// app-accessible canonical mount path `/storage/emulated/<id>/...`.
  static String? rewriteAndroidMountPath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return null;
    final m1 = _androidMntUserPattern.firstMatch(trimmed);
    if (m1 != null) {
      return '/storage/emulated/${m1.group(1)}${m1.group(2) ?? ''}';
    }
    final m2 = _androidMntRuntimePattern.firstMatch(trimmed);
    if (m2 != null) {
      return '/storage/emulated/${m2.group(1)}${m2.group(2) ?? ''}';
    }
    final m3 = _androidDataMediaPattern.firstMatch(trimmed);
    if (m3 != null) {
      return '/storage/emulated/${m3.group(1)}${m3.group(2) ?? ''}';
    }
    return null;
  }

  /// Returns ordered candidate paths for a symlink target: first the exact [targetPath],
  /// followed by its canonical `/storage/emulated/<id>/...` equivalent if it is an
  /// Android internal FUSE / `sdcardfs` path.
  static List<String> candidatePathsForTarget(String targetPath) {
    final clean = targetPath.trim();
    if (clean.isEmpty) return const [];
    final rewritten = rewriteAndroidMountPath(clean);
    if (rewritten != null && rewritten != clean) {
      return <String>[clean, rewritten];
    }
    return <String>[clean];
  }

  /// Precaución 5: Normalizes a local filesystem path into its canonical identity
  /// for `EngineItem.sourceKey` deduplication.
  static String canonicalizeLocalPathForKey(String path) {
    final normalized = FileByteProvider.normalizeFileUriOrPath(path);
    if (normalized.isEmpty) return '';
    if (isWindowsFilePath(normalized)) {
      if (normalized.startsWith(r'\\')) {
        return r'\\' +
            normalized
                .substring(2)
                .replaceAll('/', r'\')
                .replaceAll(RegExp(r'\\+'), r'\');
      }
      final drive = normalized[0].toUpperCase();
      final rest = normalized
          .substring(2)
          .replaceAll(r'\', '/')
          .replaceAll(RegExp(r'/+'), '/');
      return '$drive:$rest';
    }
    final rewritten = rewriteAndroidMountPath(normalized) ?? normalized;
    final collapsed = rewritten
        .replaceAll(RegExp(r'/\./'), '/')
        .replaceAll(RegExp(r'/+'), '/');
    return collapsed;
  }

  /// Precaución 3: Returns `true` if a `/proc/self/fd/<fd>` symlink target points
  /// to a non-seekable kernel pipe, socket, or anonymous inode.
  static bool isNonSeekableFdTarget(String? linkTarget) {
    if (linkTarget == null) return false;
    final t = linkTarget.trim();
    return t.startsWith('pipe:') ||
        t.startsWith('socket:') ||
        t.startsWith('anon_inode:');
  }

  /// Precaución 3: Returns `true` if a `/proc/self/fd/<fd>` symlink target points
  /// to an unlinked/deleted file (`" (deleted)"`).
  static bool isDeletedFdTarget(String? linkTarget) {
    if (linkTarget == null) return false;
    return linkTarget.endsWith(' (deleted)');
  }

  /// Precaución 3: Returns `true` if [linkTarget] is a regular filesystem path
  /// eligible for Level 1 promotion (`FileByteProvider`).
  static bool isPromotableFdTarget(String? linkTarget) {
    if (linkTarget == null) return false;
    final t = linkTarget.trim();
    if (t.isEmpty) return false;
    if (isNonSeekableFdTarget(t) || isDeletedFdTarget(t)) return false;
    return t.startsWith('/') || isWindowsFilePath(t);
  }

  /// Extracts a numeric file descriptor from `fd://<fd>`, `fd:<fd>`, or `/proc/self/fd/<fd>`.
  static int? extractFdFromUriOrPath(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;
    final m1 = _fdSchemePattern.firstMatch(trimmed);
    if (m1 != null) {
      final numStr = m1.group(1) ?? m1.group(2);
      return numStr != null ? int.tryParse(numStr) : null;
    }
    final m2 = _procFdPathPattern.firstMatch(trimmed);
    if (m2 != null) {
      final numStr = m2.group(1);
      return numStr != null ? int.tryParse(numStr) : null;
    }
    return null;
  }

  /// Checks whether [path] is a regular file that can be directly opened and read
  /// by the application process.
  static bool isDirectlyReadable(String path) {
    if (path.isEmpty) return false;
    final probe = MiniaudioPlayerGlobalConfig.directFileAccessProbe;
    if (probe != null) {
      return probe(path);
    }
    return isDirectlyReadableRegularFile(path);
  }

  /// Evaluates [candidates] (and their Android mount rewrites) in order and returns
  /// the first directly readable regular file path, or `null` if none is accessible.
  static String? resolveDirectlyReadableCandidate(Iterable<String> candidates) {
    for (final rawCandidate in candidates) {
      for (final candidate in candidatePathsForTarget(rawCandidate)) {
        if (isDirectlyReadable(candidate)) {
          return candidate;
        }
      }
    }
    return null;
  }

  /// Reads the symbolic link target of `/proc/self/fd/<fd>`.
  static String? inspectFdSymbolicLink(int fd) {
    if (fd < 0) return null;
    final customResolver = MiniaudioPlayerGlobalConfig.fdLinkResolver;
    if (customResolver != null) {
      final res = customResolver(fd);
      if (res != null) return res;
    }
    return readFdSymbolicLink(fd);
  }

  /// Inspects `/proc/self/fd/<fd>` and returns a directly readable local file path
  /// if the descriptor can be promoted to Level 1 (`FileByteProvider`), or `null` otherwise.
  static String? tryResolvePromotablePathFromFd(int fd) {
    final target = inspectFdSymbolicLink(fd);
    if (!isPromotableFdTarget(target)) {
      return null;
    }
    return resolveDirectlyReadableCandidate(<String>[target!]);
  }

  /// Closes a detached native file descriptor using [MiniaudioPlayerGlobalConfig.fdCloser]
  /// or POSIX `close(fd)`.
  static Future<void> closeNativeFd(int fd) async {
    if (fd < 0) return;
    final closer = MiniaudioPlayerGlobalConfig.fdCloser;
    if (closer != null) {
      await closer(fd);
    } else {
      closeNativeFdSync(fd);
    }
  }

  /// Executes Level 1 vs Level 2 promotion for an open file descriptor [fd].
  ///
  /// Precaución 1: Guarantees in a `try/finally` block that if [fd] is promoted
  /// to a Level 1 [FileByteProvider] (or if resolution is cancelled/throws),
  /// the temporary [fd] is closed immediately before returning.
  static Future<AudioByteProvider> promoteOrWrapFd(
    int fd, {
    Uri? uri,
    bool ownFd = true,
    bool Function()? isCancelled,
  }) async {
    if (fd < 0) {
      throw MiniaudioPlayerException(
        'Invalid file descriptor: $fd',
        errorCode: MapResult.errorInvalidArgs,
      );
    }
    bool handedToFdProvider = false;
    try {
      if (isCancelled != null && isCancelled()) {
        throw const MiniaudioPlayerException(
          'URI resolution cancelled before inspecting descriptor',
          errorCode: MapResult.errorGeneric,
        );
      }
      final promotedPath = tryResolvePromotablePathFromFd(fd);
      if (isCancelled != null && isCancelled()) {
        throw const MiniaudioPlayerException(
          'URI resolution cancelled after inspecting descriptor',
          errorCode: MapResult.errorGeneric,
        );
      }
      if (promotedPath != null) {
        return FileByteProvider(promotedPath);
      }
      final linkTarget = inspectFdSymbolicLink(fd);
      final bool nonSeekable = isNonSeekableFdTarget(linkTarget);
      handedToFdProvider = true;
      return FdByteProvider(
        fd,
        uri: uri,
        ownFd: ownFd,
        isSeekable: nonSeekable ? false : null,
      );
    } finally {
      if (ownFd && !handedToFdProvider) {
        await closeNativeFd(fd);
      }
    }
  }

  /// Paso 1: Synchronously deduces local filesystem candidate paths from a `content://`,
  /// `fd://`, or `/proc/self/fd/<fd>` [Uri] without opening new descriptors.
  static UriPathDeduction deduceLocalPathFromUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();

    // 1. Check fd:// or /proc/self/fd/<fd>
    final fd = extractFdFromUriOrPath(uri.toString());
    if (fd != null) {
      final linkTarget = inspectFdSymbolicLink(fd);
      if (isPromotableFdTarget(linkTarget)) {
        final candidates = candidatePathsForTarget(linkTarget!);
        final readable = resolveDirectlyReadableCandidate(candidates);
        final canonical =
            readable ?? rewriteAndroidMountPath(linkTarget) ?? linkTarget;
        return UriPathDeduction(
          canonicalPath: canonical,
          candidatePaths: candidates,
        );
      }
      return const UriPathDeduction();
    }

    if (scheme != 'content') {
      return const UriPathDeduction();
    }

    final rawPath = uri.path;

    // 2. Check SAF /document/<encodedDocId> segment (Precaución 7: decode ONLY the document segment)
    const docMarker = '/document/';
    final docIdx = rawPath.indexOf(docMarker);
    if (docIdx != -1) {
      final rawDocSegment = rawPath.substring(docIdx + docMarker.length);
      if (rawDocSegment.isEmpty) {
        return const UriPathDeduction();
      }
      final String docId;
      try {
        docId = Uri.decodeComponent(rawDocSegment);
      } catch (_) {
        return const UriPathDeduction(rejectedByPathTraversal: true);
      }

      if (docId.toLowerCase().startsWith('raw:')) {
        final embeddedPath = docId.substring(4).trim();
        if (embeddedPath.isEmpty || hasPathTraversal(embeddedPath)) {
          return const UriPathDeduction(rejectedByPathTraversal: true);
        }
        // If embeddedPath is relative and appDirectories are registered, resolve within them
        if (!embeddedPath.startsWith('/') && !isWindowsFilePath(embeddedPath)) {
          final appCands = _resolveRelativeAgainstAppDirs([embeddedPath]);
          if (appCands.isEmpty) {
            return const UriPathDeduction(rejectedByPathTraversal: true);
          }
          final readable = resolveDirectlyReadableCandidate(appCands);
          return UriPathDeduction(
            canonicalPath: readable ?? appCands.first,
            candidatePaths: appCands,
          );
        }
        final candidates = candidatePathsForTarget(embeddedPath);
        final readable = resolveDirectlyReadableCandidate(candidates);
        final canonical =
            readable ?? rewriteAndroidMountPath(embeddedPath) ?? embeddedPath;
        return UriPathDeduction(
          canonicalPath: canonical,
          candidatePaths: candidates,
        );
      }

      if (docId.toLowerCase().startsWith('primary:')) {
        final relPath = docId.substring('primary:'.length).trim();
        if (relPath.isEmpty || hasPathTraversal(relPath)) {
          return const UriPathDeduction(rejectedByPathTraversal: true);
        }
        final primaryResolved =
            resolveWithinRoot('/storage/emulated/0', relPath);
        if (primaryResolved == null) {
          return const UriPathDeduction(rejectedByPathTraversal: true);
        }
        final appCands = _resolveRelativeAgainstAppDirs(
          relPath.replaceAll('\\', '/').split('/').where((s) => s.isNotEmpty).toList(),
        );
        final allCands = <String>[primaryResolved, ...appCands];
        final readable = resolveDirectlyReadableCandidate(allCands);
        return UriPathDeduction(
          canonicalPath: readable ?? primaryResolved,
          candidatePaths: allCands,
        );
      }

      final colonIdx = docId.indexOf(':');
      if (colonIdx > 0) {
        final prefix = docId.substring(0, colonIdx).trim();
        final afterColon = docId.substring(colonIdx + 1).trim();
        if (hasPathTraversal(afterColon) || hasPathTraversal(prefix)) {
          return const UriPathDeduction(rejectedByPathTraversal: true);
        }
        // Opaque MediaStore document ID (e.g. audio:10452, msf:42)
        if (_opaqueMediaDocPrefix.hasMatch(prefix) &&
            RegExp(r'^\d+$').hasMatch(afterColon)) {
          return const UriPathDeduction();
        }
        if (afterColon.isNotEmpty &&
            RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(prefix)) {
          final volResolved = resolveWithinRoot('/storage/$prefix', afterColon);
          if (volResolved == null) {
            return const UriPathDeduction(rejectedByPathTraversal: true);
          }
          return UriPathDeduction(
            canonicalPath: volResolved,
            candidatePaths: <String>[volResolved],
          );
        }
      } else if (hasPathTraversal(docId)) {
        return const UriPathDeduction(rejectedByPathTraversal: true);
      }
    }

    // 3. Non-SAF content:// URI: validate every segment against Path Traversal (Precaución 7)
    if (hasPathTraversal(rawPath)) {
      return const UriPathDeduction(rejectedByPathTraversal: true);
    }

    final decodedSegments = <String>[];
    for (final rawSeg in uri.pathSegments) {
      if (rawSeg.isEmpty) continue;
      final String seg;
      try {
        seg = Uri.decodeComponent(rawSeg);
      } catch (_) {
        return const UriPathDeduction(rejectedByPathTraversal: true);
      }
      if (seg == '..' || hasPathTraversal(seg)) {
        return const UriPathDeduction(rejectedByPathTraversal: true);
      }
      decodedSegments.add(seg);
    }

    if (decodedSegments.isEmpty) {
      return const UriPathDeduction();
    }

    // Standard Android MediaStore URIs (content://media/external/audio/media/10452)
    // are opaque IDs resolved in Step 2 via /proc/self/fd/<fd>.
    if (uri.authority.toLowerCase() == 'media') {
      return const UriPathDeduction();
    }

    final candidates = _resolveRelativeAgainstAppDirs(decodedSegments);
    if (candidates.isNotEmpty) {
      final readable = resolveDirectlyReadableCandidate(candidates);
      return UriPathDeduction(
        canonicalPath: readable ?? candidates.first,
        candidatePaths: candidates,
      );
    }

    return const UriPathDeduction();
  }

  static List<String> _resolveRelativeAgainstAppDirs(
    List<String> decodedSegments,
  ) {
    if (decodedSegments.isEmpty) return const [];
    final aliasMap = <String, String>{
      ...MiniaudioPlayerGlobalConfig.fileProviderAliases,
    };
    final appDirs = <String>[];

    for (final entry in MiniaudioPlayerGlobalConfig.appDirectories) {
      final trimmed = entry.trim();
      if (trimmed.isEmpty) continue;
      final eqIdx = trimmed.indexOf('=');
      if (eqIdx > 0 &&
          !trimmed.substring(0, eqIdx).contains('/') &&
          !trimmed.substring(0, eqIdx).contains(r'\')) {
        final alias = trimmed.substring(0, eqIdx).trim();
        final dir = trimmed.substring(eqIdx + 1).trim();
        if (alias.isNotEmpty && dir.isNotEmpty) {
          aliasMap[alias] = dir;
          appDirs.add(dir);
        }
      } else {
        appDirs.add(trimmed);
      }
    }

    if (aliasMap.isEmpty && appDirs.isEmpty) {
      return const [];
    }

    final candidates = <String>[];
    void addCandidate(String? path) {
      if (path != null && path.isNotEmpty && !candidates.contains(path)) {
        candidates.add(path);
      }
    }

    final fullRel = decodedSegments.join('/');
    final strippedRel =
        decodedSegments.length >= 2 ? decodedSegments.skip(1).join('/') : null;

    if (decodedSegments.length >= 2 &&
        aliasMap.containsKey(decodedSegments.first)) {
      addCandidate(
        resolveWithinRoot(aliasMap[decodedSegments.first]!, strippedRel!),
      );
    }

    for (final rawDir in appDirs) {
      final normDir = rawDir
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+'), '/')
          .replaceAll(RegExp(r'/+$'), '');
      if (normDir.isEmpty) continue;

      // Check if the URI path already contains normDir as an absolute prefix
      final asAbs = '/$fullRel';
      if (asAbs.startsWith('$normDir/')) {
        final insideRel = asAbs.substring(normDir.length + 1);
        addCandidate(resolveWithinRoot(normDir, insideRel));
      }

      // Candidate 1: <appDir>/<fullRel>
      addCandidate(resolveWithinRoot(normDir, fullRel));

      // Candidate 2: <appDir>/<strippedRel> (when first segment is a FileProvider root alias)
      if (strippedRel != null && strippedRel.isNotEmpty) {
        addCandidate(resolveWithinRoot(normDir, strippedRel));
      }
    }

    return candidates;
  }
}

/// Level 2 [AudioByteProvider] backed by an open kernel file descriptor (`int fd` / `/proc/self/fd/<fd>`)
/// or a mutex-protected random-access file handle.
///
/// Features:
/// - `O(1)` memory footprint (never copies the file to RAM or temporary cache files).
/// - `O(1)` random-access seeking and concurrent `probeTail` via atomic `pread` or
///   FIFO async mutex (`_withIoLock`) over a shared random-access handle (Precaución 2).
/// - Automatic sequential stream fallback (`isSeekable: false`, `probeTail() == null`)
///   when the underlying descriptor is a `pipe:`, `socket:`, or `anon_inode:` (Precaución 3).
/// - Strict idempotent `close()` (`_isClosed` guard) preventing `EMFILE` leaks and
///   POSIX double-close hazards (Precaución 1).
class FdByteProvider extends AudioByteProvider {
  /// Underlying OS file descriptor number.
  final int fd;

  final Uri? _uri;

  /// Whether this provider owns [fd] and must close it when [close] is invoked.
  final bool ownFd;

  /// Optional shared random-access handle (`RandomAccessFile` or compatible adapter)
  /// whose `setPosition` + `read` calls are strictly serialized by an async mutex.
  final dynamic _sharedHandle;

  final FutureOr<void> Function(int fd)? _onCloseFd;
  final bool? _isSeekableOverride;
  final int? _totalBytesOverride;

  /// Chunk size in bytes emitted when streaming from the descriptor.
  final int chunkSize;

  bool _isClosed = false;
  int _closeCount = 0;
  int _activeReadGeneration = 0;
  Future<void> _ioMutexTail = Future<void>.value();

  FdByteProvider(
    this.fd, {
    Uri? uri,
    this.ownFd = true,
    dynamic sharedHandle,
    FutureOr<void> Function(int fd)? onCloseFd,
    bool? isSeekable,
    int? totalBytes,
    this.chunkSize = 65536,
  })  : _uri = uri,
        _sharedHandle = sharedHandle,
        _onCloseFd = onCloseFd,
        _isSeekableOverride = isSeekable,
        _totalBytesOverride = totalBytes;

  /// Whether [close] has already been invoked on this provider.
  bool get isClosed => _isClosed;

  /// Number of times the underlying native descriptor was actually closed (at most `1`).
  int get nativeCloseCount => _closeCount;

  /// Path in the Linux/Android virtual procfs for this descriptor.
  String get procFdPath => '/proc/self/fd/$fd';

  @override
  String get sourceId => _uri?.toString() ?? 'fd://$fd';

  @override
  Uri? get uri => _uri ?? Uri.parse('fd://$fd');

  @override
  bool get isLiveStream => _isSeekableOverride == false;

  /// Precaución 2: Serializes concurrent cursor operations (`setPosition` + `read`)
  /// in strict FIFO order so `probeTail()` and `open()` never collide on a shared handle.
  Future<T> _withIoLock<T>(Future<T> Function() action) {
    final prev = _ioMutexTail;
    final completer = Completer<void>();
    _ioMutexTail = completer.future;
    return prev.then((_) => action()).whenComplete(() {
      if (!completer.isCompleted) {
        completer.complete();
      }
    });
  }

  bool _resolveIsSeekable() {
    final override = _isSeekableOverride;
    if (override != null) return override;
    if (_sharedHandle != null) return true;
    final linkTarget = UriCapabilityResolver.inspectFdSymbolicLink(fd);
    if (UriCapabilityResolver.isNonSeekableFdTarget(linkTarget)) {
      return false;
    }
    return isNativeFdSeekable(fd);
  }

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    if (_isClosed) {
      throw MiniaudioPlayerException(
        'Cannot open closed file descriptor (fd: $fd)',
        errorCode: MapResult.errorInvalidState,
      );
    }

    final int gen = ++_activeReadGeneration;
    final bool seekable = _resolveIsSeekable();

    // Non-seekable descriptor (pipe, socket, anon_inode -> Level 4 sequential stream)
    if (!seekable) {
      return AudioByteStreamResponse(
        stream: _createSequentialFdStream(gen),
        totalBytes: -1,
        isSeekable: false,
        isLive: false,
      );
    }

    final int totalBytes;
    if (_sharedHandle != null) {
      try {
        totalBytes = _totalBytesOverride ??
            await _withIoLock(() => rafLength(_sharedHandle));
      } catch (e) {
        throw MiniaudioPlayerException(
          'Failed to query length on shared descriptor handle (fd: $fd): $e',
          errorCode: MapResult.errorDecodeFailed,
        );
      }
    } else {
      totalBytes = _totalBytesOverride ?? getNativeFdLength(fd);
    }

    if (totalBytes == 0) {
      throw MiniaudioPlayerException(
        'Cannot open empty file descriptor (fd: $fd)',
        errorCode: MapResult.errorDecodeFailed,
      );
    }
    if (totalBytes < 0) {
      throw MiniaudioPlayerException(
        'Failed to access file descriptor (fd: $fd)',
        errorCode: MapResult.errorFileNotFound,
      );
    }

    final int start = offset.clamp(0, totalBytes);
    final int end = length != null
        ? (start + length).clamp(start, totalBytes)
        : totalBytes;

    return AudioByteStreamResponse(
      stream: _createSeekableFdStream(gen, start, end),
      totalBytes: totalBytes,
      isSeekable: true,
      isLive: false,
    );
  }

  Stream<Uint8List> _createSeekableFdStream(int gen, int start, int end) {
    late StreamController<Uint8List> controller;
    bool cancelled = false;
    bool paused = false;
    Completer<void>? resumeCompleter;

    Future<void> pump() async {
      int currentOffset = start;
      try {
        while (!cancelled &&
            !_isClosed &&
            _activeReadGeneration == gen &&
            currentOffset < end) {
          if (paused) {
            resumeCompleter = Completer<void>();
            await resumeCompleter!.future;
            resumeCompleter = null;
            if (cancelled || _isClosed || _activeReadGeneration != gen) break;
          }

          final int toRead = min(chunkSize, end - currentOffset);
          final int readAtOffset = currentOffset;

          Uint8List? chunk;
          if (_sharedHandle != null) {
            chunk = await _withIoLock<Uint8List>(() async {
              if (_isClosed) return Uint8List(0);
              await rafSetPosition(_sharedHandle, readAtOffset);
              return await rafRead(_sharedHandle, toRead);
            });
          } else {
            chunk = await _withIoLock<Uint8List?>(() async {
              if (_isClosed) return null;
              return preadNativeFd(fd, readAtOffset, toRead);
            });
          }

          if (cancelled || _isClosed || _activeReadGeneration != gen) break;
          if (chunk == null || chunk.isEmpty) {
            break;
          }

          currentOffset += chunk.length;
          if (!controller.isClosed) {
            controller.add(chunk);
          }

          // Yield to event loop so concurrent probeTail() or stream pause/cancel can interleave cleanly
          await Future<void>.delayed(Duration.zero);
        }
        if (!controller.isClosed) {
          await controller.close();
        }
      } catch (e, st) {
        if (!cancelled && !_isClosed && !controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    }

    controller = StreamController<Uint8List>(
      onListen: pump,
      onPause: () {
        paused = true;
      },
      onResume: () {
        paused = false;
        if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
          resumeCompleter!.complete();
        }
      },
      onCancel: () {
        cancelled = true;
        if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
          resumeCompleter!.complete();
        }
      },
    );

    return controller.stream;
  }

  Stream<Uint8List> _createSequentialFdStream(int gen) {
    late StreamController<Uint8List> controller;
    bool cancelled = false;
    bool paused = false;
    Completer<void>? resumeCompleter;

    Future<void> pump() async {
      try {
        while (!cancelled && !_isClosed && _activeReadGeneration == gen) {
          if (paused) {
            resumeCompleter = Completer<void>();
            await resumeCompleter!.future;
            resumeCompleter = null;
            if (cancelled || _isClosed || _activeReadGeneration != gen) break;
          }

          Uint8List? chunk;
          if (_sharedHandle != null) {
            chunk = await _withIoLock<Uint8List>(() async {
              if (_isClosed) return Uint8List(0);
              return await rafRead(_sharedHandle, chunkSize);
            });
          } else {
            final ready = await _withIoLock<bool>(() async {
              if (_isClosed) return true;
              return isNativeFdReadyToRead(fd);
            });
            if (cancelled || _isClosed || _activeReadGeneration != gen) break;
            if (!ready) {
              await Future<void>.delayed(const Duration(milliseconds: 2));
              continue;
            }
            chunk = await _withIoLock<Uint8List?>(() async {
              if (_isClosed) return null;
              return readSequentialNativeFd(fd, chunkSize);
            });
          }

          if (cancelled || _isClosed || _activeReadGeneration != gen) break;
          if (chunk == null || chunk.isEmpty) {
            break;
          }

          if (!controller.isClosed) {
            controller.add(chunk);
          }
          await Future<void>.delayed(Duration.zero);
        }
        if (!controller.isClosed) {
          await controller.close();
        }
      } catch (e, st) {
        if (!cancelled && !_isClosed && !controller.isClosed) {
          controller.addError(e, st);
          await controller.close();
        }
      }
    }

    controller = StreamController<Uint8List>(
      onListen: pump,
      onPause: () {
        paused = true;
      },
      onResume: () {
        paused = false;
        if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
          resumeCompleter!.complete();
        }
      },
      onCancel: () {
        cancelled = true;
        if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
          resumeCompleter!.complete();
        }
      },
    );

    return controller.stream;
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    if (_isClosed || tailOffset < 0 || length <= 0) return null;
    if (!_resolveIsSeekable()) return null;

    try {
      if (_sharedHandle != null) {
        return await _withIoLock<Uint8List?>(() async {
          if (_isClosed) return null;
          final total = _totalBytesOverride ?? await rafLength(_sharedHandle);
          if (tailOffset >= total) return null;
          final toRead = min(length, total - tailOffset);
          await rafSetPosition(_sharedHandle, tailOffset);
          return await rafRead(_sharedHandle, toRead);
        });
      }
      return await _withIoLock<Uint8List?>(() async {
        if (_isClosed) return null;
        return preadNativeFd(fd, tailOffset, length);
      });
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> abortActiveStream() async {
    _activeReadGeneration++;
  }

  @override
  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _activeReadGeneration++;
    await _withIoLock(() async {
      if (_sharedHandle != null) {
        try {
          await rafClose(_sharedHandle);
        } catch (_) {}
      }
      if (ownFd && fd >= 0) {
        _closeCount++;
        final closer = _onCloseFd ?? MiniaudioPlayerGlobalConfig.fdCloser;
        if (closer != null) {
          await closer(fd);
        } else {
          closeNativeFdSync(fd);
        }
      }
    });
  }
}

/// Orchestrates lazy Capability Promotion for `content://`, `fd://`, `/proc/self/fd/<fd>`,
/// and custom URI schemes at open time.
class ResolvingByteProvider extends AudioByteProvider {
  final Uri _uri;
  final String? canonicalFilePath;
  final Map<String, String>? headers;
  final bool _isLiveHint;
  final bool ownFd;
  final bool rejectedByPathTraversal;

  AudioByteProvider? _resolvedProvider;
  bool _isClosed = false;

  ResolvingByteProvider(
    Uri uri, {
    this.canonicalFilePath,
    this.headers,
    bool isLive = false,
    this.ownFd = true,
    this.rejectedByPathTraversal = false,
  })  : _uri = uri,
        _isLiveHint = isLive;

  /// The promoted physical [AudioByteProvider] ([FileByteProvider], [FdByteProvider],
  /// [NetworkByteProvider], etc.) once resolved.
  AudioByteProvider? get resolvedProvider => _resolvedProvider;

  /// Whether [close] has been called on this provider.
  bool get isClosed => _isClosed;

  @override
  String get sourceId => _resolvedProvider?.sourceId ?? _uri.toString();

  @override
  Uri? get uri => _resolvedProvider?.uri ?? _uri;

  @override
  bool get isLiveStream => _resolvedProvider?.isLiveStream ?? _isLiveHint;

  @override
  bool get isNetwork => _resolvedProvider?.isNetwork ?? false;

  /// Runs the 2-step Capability Promotion pipeline and returns the promoted
  /// physical [AudioByteProvider].
  Future<AudioByteProvider> resolveProvider({
    bool Function()? isCancelled,
  }) async {
    bool checkCancelled() =>
        _isClosed || (isCancelled != null && isCancelled());

    if (checkCancelled()) {
      throw const MiniaudioPlayerException(
        'ResolvingByteProvider closed before resolution',
        errorCode: MapResult.errorGeneric,
      );
    }

    if (_resolvedProvider != null) {
      return _resolvedProvider!;
    }

    // Security check (Precaución 7)
    if (rejectedByPathTraversal) {
      throw MiniaudioPlayerException(
        'Path traversal rejected in URI: $_uri',
        errorCode: MapResult.errorAccessDenied,
      );
    }

    final deduction = UriCapabilityResolver.deduceLocalPathFromUri(_uri);
    if (deduction.rejectedByPathTraversal) {
      throw MiniaudioPlayerException(
        'Path traversal rejected in URI: $_uri',
        errorCode: MapResult.errorAccessDenied,
      );
    }

    // Step 1: Check if a local path is directly deducible and readable without opening an fd
    final step1Candidates = <String>[
      if (canonicalFilePath != null && canonicalFilePath!.isNotEmpty)
        canonicalFilePath!,
      ...deduction.candidatePaths,
    ];
    if (step1Candidates.isNotEmpty) {
      final readablePath =
          UriCapabilityResolver.resolveDirectlyReadableCandidate(
        step1Candidates,
      );
      if (readablePath != null) {
        final promoted = FileByteProvider(readablePath);
        _resolvedProvider = promoted;
        return promoted;
      }
    }

    // Step 2A: Direct fd:// or /proc/self/fd/<fd> URI
    final embeddedFd =
        UriCapabilityResolver.extractFdFromUriOrPath(_uri.toString());
    if (embeddedFd != null) {
      final promoted = await UriCapabilityResolver.promoteOrWrapFd(
        embeddedFd,
        uri: _uri,
        ownFd: ownFd,
        isCancelled: checkCancelled,
      );
      _resolvedProvider = promoted;
      return promoted;
    }

    // Step 2B: Open descriptor via contentFdOpener (e.g. Android ContentResolver)
    final fdOpener = MiniaudioPlayerGlobalConfig.contentFdOpener;
    if (fdOpener != null) {
      final int? openedFd = await fdOpener(_uri);
      if (openedFd != null && openedFd >= 0) {
        final promoted = await UriCapabilityResolver.promoteOrWrapFd(
          openedFd,
          uri: _uri,
          ownFd: true,
          isCancelled: checkCancelled,
        );
        _resolvedProvider = promoted;
        return promoted;
      }
    }

    // Step 2C: Custom uriResolver fallback (e.g. virtual cloud streams or custom protocols)
    final customResolver = MiniaudioPlayerGlobalConfig.uriResolver;
    if (customResolver != null) {
      final customProvider = await customResolver(_uri, headers: headers);
      if (checkCancelled()) {
        await customProvider?.close();
        throw const MiniaudioPlayerException(
          'URI resolution cancelled while awaiting uriResolver',
          errorCode: MapResult.errorGeneric,
        );
      }
      if (customProvider != null) {
        _resolvedProvider = customProvider;
        return customProvider;
      }
    }

    throw MiniaudioPlayerException(
      'Unable to resolve URI "$_uri": resource is not directly readable and no contentFdOpener or uriResolver provided a handle.',
      errorCode: MapResult.errorFileNotFound,
    );
  }

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    final provider = await resolveProvider();
    return provider.open(offset: offset, length: length);
  }

  @override
  Future<Uint8List?> probeTail(int tailOffset, int length) async {
    final provider = _resolvedProvider;
    if (provider == null) return null;
    return provider.probeTail(tailOffset, length);
  }

  @override
  Future<void> abortActiveStream() async {
    await _resolvedProvider?.abortActiveStream();
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    final provider = _resolvedProvider;
    if (provider != null) {
      await provider.close();
    }
  }
}

