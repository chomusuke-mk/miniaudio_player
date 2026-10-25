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

  /// Closes any active file handles or network connections held by this provider.
  Future<void> close();
}

/// Provides audio bytes directly from an in-memory [Uint8List].
class MemoryByteProvider extends AudioByteProvider {
  final Uint8List _bytes;
  final String _label;
  final Uri? _uri;
  MemoryByteProvider(
    this._bytes, {
    String label = 'memory://buffer',
    Uri? uri,
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

  /// Normalizes a `file://` URI or raw filesystem path into an OS path.
  static String normalizeFileUriOrPath(String path) {
    final trimmed = path.trim();
    if (trimmed.toLowerCase().startsWith('file://')) {
      try {
        final uri = Uri.parse(trimmed);
        return uri.toFilePath();
      } catch (_) {
        final withoutScheme =
            trimmed.replaceFirst(RegExp(r'^file://(localhost)?', caseSensitive: false), '');
        return Uri.decodeFull(withoutScheme);
      }
    }
    return trimmed;
  }

  @override
  String get sourceId => filePath;

  @override
  Uri? get uri => Uri.file(filePath);

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
        throw MiniaudioPlayerException(
          'Failed to connect to $_uri: $e',
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
      bool isSeekable = res.headers['accept-ranges']?.toLowerCase() == 'bytes';

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

