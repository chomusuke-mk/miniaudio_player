import 'dart:typed_data';

import '../loader/audio_byte_provider.dart';
import '../platform/fs_helper.dart';
import 'player_exception.dart';

/// Represents a source of audio playable by `MiniaudioPlayer`.
sealed class AudioSource {
  const AudioSource();

  /// The [Uri] associated with this audio source, if applicable.
  Uri? get uri;

  /// Creates an audio source backed by a local filesystem file path.
  const factory AudioSource.file(String filePath) = FileAudioSource;

  /// Creates an audio source loaded directly from Flutter bundle assets without disk I/O.
  const factory AudioSource.asset(String assetKey, {String? package}) =
      AssetAudioSource;

  /// Creates an audio source backed by an in-memory byte buffer (RAM).
  const factory AudioSource.memory(
    Uint8List bytes, {
    String? mimeType,
    Uri? uri,
  }) = MemoryAudioSource;

  /// Creates an audio source from a remote HTTP or HTTPS URL (progressive file or auto-detected live stream).
  const factory AudioSource.network(
    Uri uri, {
    Map<String, String>? headers,
    bool enableCache,
    Duration bufferAhead,
    bool isLive,
  }) = NetworkAudioSource;

  /// Creates an audio source for a continuous live web stream (Internet Radio, Icecast).
  const factory AudioSource.liveStream(
    Uri uri, {
    Map<String, String>? headers,
    Duration jitterBuffer,
  }) = LiveStreamAudioSource;

  /// Creates an audio source backed by a custom [AudioByteProvider].
  const factory AudioSource.custom(AudioByteProvider provider) =
      CustomAudioSource;

  /// Creates an audio source for an opaque or capability-promoted URI (`content://`, `fd://`, etc.).
  const factory AudioSource.resolving(
    Uri uri, {
    String? canonicalFilePath,
    Map<String, String>? headers,
    Duration? bufferAhead,
    bool isLive,
    bool ownFd,
    bool rejectedByPathTraversal,
  }) = ResolvingAudioSource;

  /// Creates an audio source backed by an open native file descriptor (`fd://<fd>`).
  factory AudioSource.fd(
    int fd, {
    bool ownFd = true,
    Duration? bufferAhead,
  }) {
    final uri = Uri.parse('fd://$fd');
    final deduction = UriCapabilityResolver.deduceLocalPathFromUri(uri);
    return ResolvingAudioSource(
      uri,
      canonicalFilePath: deduction.canonicalPath,
      bufferAhead: bufferAhead,
      ownFd: ownFd,
    );
  }

  /// Auto-resolves a URI string, [Uri], [AudioSource], [AudioByteProvider],
  /// [Uint8List], or `FileSystemEntity` into the appropriate [AudioSource]
  /// following the Capability Promotion pipeline (`URI_IMPLEMENTATION.md`).
  factory AudioSource.uri(
    dynamic uriOrPath, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
  }) {
    if (uriOrPath is AudioSource) return uriOrPath;
    if (uriOrPath is AudioByteProvider) return CustomAudioSource(uriOrPath);
    if (uriOrPath is Uint8List) return MemoryAudioSource(uriOrPath);
    if (isFsEntity(uriOrPath)) {
      final fsPath = getFsPath(uriOrPath);
      if (fsPath != null) {
        return FileAudioSource(fsPath);
      }
    }

    final str = uriOrPath.toString().trim();
    if (str.isEmpty) {
      return const FileAudioSource('');
    }

    // Precaución 4: Classify Windows drive paths (C:\... or C:/...) and UNC paths (\\server\share)
    // immediately as FileAudioSource BEFORE evaluating URI schemes.
    if (UriCapabilityResolver.isWindowsFilePath(str)) {
      return FileAudioSource(str);
    }

    // Check fd:// or /proc/self/fd/<fd> (and file:///proc/self/fd/<fd>)
    final fdNum = UriCapabilityResolver.extractFdFromUriOrPath(str);
    if (fdNum != null) {
      final fdUri = Uri.parse('fd://$fdNum');
      final deduction = UriCapabilityResolver.deduceLocalPathFromUri(fdUri);
      return ResolvingAudioSource(
        fdUri,
        canonicalFilePath: deduction.canonicalPath,
        headers: headers,
        bufferAhead: bufferAhead,
        isLive: isLive,
      );
    }

    final lower = str.toLowerCase();

    // RFC 2397 data: URI -> Level 3 (MemoryAudioSource)
    if (lower.startsWith('data:')) {
      try {
        final UriData uriData = (uriOrPath is Uri && uriOrPath.data != null)
            ? uriOrPath.data!
            : UriData.parse(str);
        final bytes = uriData.contentAsBytes();
        final mime = uriData.mimeType;
        return MemoryAudioSource(
          bytes,
          mimeType: mime.isNotEmpty ? mime : null,
          uri: uriOrPath is Uri ? uriOrPath : Uri.tryParse(str),
        );
      } catch (e) {
        throw MiniaudioPlayerException(
          'Invalid RFC 2397 data: URI: $e',
          errorCode: MapResult.errorInvalidArgs,
        );
      }
    }

    // package:<pkg>/<asset_path> -> Level 3 (AssetAudioSource with package)
    if (lower.startsWith('package:')) {
      final body = str.substring('package:'.length).trim();
      final slashIdx = body.indexOf('/');
      if (slashIdx <= 0 || slashIdx == body.length - 1) {
        throw MiniaudioPlayerException(
          'Invalid package: URI "$str" (expected package:<package>/<asset_path>)',
          errorCode: MapResult.errorInvalidArgs,
        );
      }
      final pkg = body.substring(0, slashIdx);
      final key = body.substring(slashIdx + 1);
      return AssetAudioSource(key, package: pkg);
    }

    // asset://, assets://, flutter-asset://, assets/ -> Level 3 (AssetAudioSource)
    if (lower.startsWith('asset://') ||
        lower.startsWith('assets://') ||
        lower.startsWith('flutter-asset://') ||
        lower.startsWith('assets/')) {
      final clean = str.replaceFirst(
        RegExp(r'^(flutter-)?asset(s)?:///?', caseSensitive: false),
        '',
      );
      final normalized =
          clean.startsWith('assets/') ? clean : 'assets/$clean';
      return AssetAudioSource(normalized);
    }

    // icy://, icys:// and icyx:// -> Level 4 (LiveStreamAudioSource over http:// or https://)
    if (lower.startsWith('icy://') ||
        lower.startsWith('icys://') ||
        lower.startsWith('icyx://')) {
      final isSecure = lower.startsWith('icys://') || lower.startsWith('icyx://');
      final httpStr = str.replaceFirst(
        RegExp(r'^icy[sx]?://', caseSensitive: false),
        isSecure ? 'https://' : 'http://',
      );
      final httpUri = Uri.parse(httpStr);
      return LiveStreamAudioSource(
        httpUri,
        headers: headers,
        jitterBuffer: bufferAhead ?? const Duration(seconds: 5),
      );
    }

    // http://, https://, blob: -> Level 4 (NetworkAudioSource / LiveStreamAudioSource)
    if (lower.startsWith('http://') ||
        lower.startsWith('https://') ||
        lower.startsWith('blob:')) {
      final parsed = uriOrPath is Uri ? uriOrPath : Uri.parse(str);
      if (isLive) {
        return LiveStreamAudioSource(
          parsed,
          headers: headers,
          jitterBuffer: bufferAhead ?? const Duration(seconds: 5),
        );
      }
      return NetworkAudioSource(
        parsed,
        headers: headers,
        bufferAhead: bufferAhead ?? const Duration(seconds: 30),
      );
    }

    // file:// -> Level 1 (FileAudioSource with decoded OS path)
    if (lower.startsWith('file://')) {
      return FileAudioSource(FileByteProvider.normalizeFileUriOrPath(str));
    }

    // content:// -> Step 1 synchronous local deduction or ResolvingAudioSource (Step 2)
    if (lower.startsWith('content://')) {
      final parsed = uriOrPath is Uri ? uriOrPath : Uri.parse(str);
      final deduction = UriCapabilityResolver.deduceLocalPathFromUri(parsed);
      if (deduction.rejectedByPathTraversal) {
        return ResolvingAudioSource(
          parsed,
          headers: headers,
          bufferAhead: bufferAhead,
          isLive: isLive,
          rejectedByPathTraversal: true,
        );
      }
      if (deduction.candidatePaths.isNotEmpty) {
        final readable = UriCapabilityResolver.resolveDirectlyReadableCandidate(
          deduction.candidatePaths,
        );
        if (readable != null) {
          return FileAudioSource(readable);
        }
      }
      return ResolvingAudioSource(
        parsed,
        canonicalFilePath: deduction.canonicalPath,
        headers: headers,
        bufferAhead: bufferAhead,
        isLive: isLive,
      );
    }

    // Custom URI schemes (e.g. customscheme://...) when not a local path
    if (!str.startsWith('/') &&
        !str.startsWith('./') &&
        !str.startsWith('../') &&
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(str)) {
      final parsed = uriOrPath is Uri ? uriOrPath : Uri.tryParse(str);
      if (parsed != null && parsed.scheme.length > 1) {
        return ResolvingAudioSource(
          parsed,
          headers: headers,
          bufferAhead: bufferAhead,
          isLive: isLive,
        );
      }
    }

    return FileAudioSource(str);
  }
}

/// A local file on the filesystem.
class FileAudioSource extends AudioSource {
  final String filePath;
  const FileAudioSource(this.filePath);

  /// Path alias for [filePath].
  String get path => filePath;

  @override
  Uri get uri => Uri.file(filePath);

  @override
  String toString() => 'FileAudioSource($filePath)';
}

/// An asset packaged in the Flutter app bundle.
class AssetAudioSource extends AudioSource {
  final String assetKey;
  final String? package;
  const AssetAudioSource(this.assetKey, {this.package});

  @override
  Uri get uri => Uri.parse(
        package != null ? 'package:$package/$assetKey' : 'asset://$assetKey',
      );

  @override
  String toString() => package != null
      ? 'AssetAudioSource(packages/$package/$assetKey)'
      : 'AssetAudioSource($assetKey)';
}

/// Audio data loaded directly from an in-memory byte buffer (RAM) or `data:` URI.
class MemoryAudioSource extends AudioSource {
  final Uint8List bytes;
  final String? mimeType;

  @override
  final Uri? uri;

  const MemoryAudioSource(
    this.bytes, {
    this.mimeType,
    this.uri,
  });

  @override
  String toString() => 'MemoryAudioSource(${bytes.lengthInBytes} bytes)';
}

/// A remote audio source (progressive file or live stream) accessed via HTTP/HTTPS or Blob URL.
///
/// Live streams are automatically detected from HTTP headers (`Content-Length`,
/// `Transfer-Encoding: chunked`, `icy-metaint`, `icy-name`, `icy-br`) even when
/// [isLive] is `false`.
class NetworkAudioSource extends AudioSource {
  @override
  final Uri uri;
  final Map<String, String>? headers;
  final bool enableCache;
  final Duration bufferAhead;

  /// Hint indicating a live stream; auto-detected at open time if `false`.
  final bool isLive;

  /// URL alias for [uri].
  Uri get url => uri;

  const NetworkAudioSource(
    this.uri, {
    this.headers,
    this.enableCache = true,
    this.bufferAhead = const Duration(seconds: 30),
    this.isLive = false,
  });

  @override
  String toString() => 'NetworkAudioSource($uri)';
}

/// A live audio stream (Internet Radio, Icecast, etc.) with a sliding jitter buffer.
///
/// Unified with [NetworkAudioSource] (`isLive: true`).
class LiveStreamAudioSource extends NetworkAudioSource {
  final Duration jitterBuffer;

  const LiveStreamAudioSource(
    super.uri, {
    super.headers,
    this.jitterBuffer = const Duration(seconds: 5),
  }) : super(
          enableCache: false,
          bufferAhead: jitterBuffer,
          isLive: true,
        );

  @override
  String toString() => 'LiveStreamAudioSource($uri)';
}

/// An audio source backed by an opaque or capability-promoted URI (`content://`, `fd://`,
/// `/proc/self/fd/<fd>`, or custom scheme).
///
/// At open time, [ResolvingAudioSource] runs the Capability Promotion pipeline to promote
/// the resource to a Level 1 [FileByteProvider] (if the underlying file is directly readable
/// by the application) or a Level 2 [FdByteProvider] (if isolated by Scoped Storage).
class ResolvingAudioSource extends AudioSource {
  /// The logical URI identifying the resource.
  @override
  final Uri uri;

  /// Optional canonical local filesystem path deduced synchronously (Precaución 5).
  final String? canonicalFilePath;

  /// Optional request headers if resolved to a network/custom stream.
  final Map<String, String>? headers;

  /// Optional ahead buffer duration.
  final Duration? bufferAhead;

  /// Whether this URI is expected to be a live stream.
  final bool isLive;

  /// Whether any descriptor embedded in [uri] (`fd://`) is owned and should be closed on dispose.
  final bool ownFd;

  /// True if the URI was flagged and rejected due to a path traversal sequence (`..`).
  final bool rejectedByPathTraversal;

  const ResolvingAudioSource(
    this.uri, {
    this.canonicalFilePath,
    this.headers,
    this.bufferAhead,
    this.isLive = false,
    this.ownFd = true,
    this.rejectedByPathTraversal = false,
  });

  @override
  String toString() => canonicalFilePath != null
      ? 'ResolvingAudioSource($uri -> $canonicalFilePath)'
      : 'ResolvingAudioSource($uri)';
}

/// A custom audio source driven by a user-supplied [AudioByteProvider].
class CustomAudioSource extends AudioSource {
  final AudioByteProvider provider;
  const CustomAudioSource(this.provider);

  @override
  Uri? get uri => provider.uri;

  @override
  String toString() => 'CustomAudioSource(${provider.sourceId})';
}

