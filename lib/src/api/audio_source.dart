import 'dart:typed_data';

import '../loader/audio_byte_provider.dart';

/// Represents a source of audio playable by `MiniaudioPlayer`.
sealed class AudioSource {
  const AudioSource();

  /// Creates an audio source backed by a local filesystem file path.
  const factory AudioSource.file(String filePath) = FileAudioSource;

  /// Creates an audio source loaded directly from Flutter bundle assets without disk I/O.
  const factory AudioSource.asset(String assetKey, {String? package}) =
      AssetAudioSource;

  /// Creates an audio source backed by an in-memory byte buffer (RAM).
  const factory AudioSource.memory(Uint8List bytes) = MemoryAudioSource;

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

  /// Auto-resolves a URI string, [Uri], [AudioSource], or [AudioByteProvider]
  /// into the appropriate [AudioSource].
  factory AudioSource.uri(
    dynamic uriOrPath, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
  }) {
    if (uriOrPath is AudioSource) return uriOrPath;
    if (uriOrPath is AudioByteProvider) return CustomAudioSource(uriOrPath);
    if (uriOrPath is Uint8List) return MemoryAudioSource(uriOrPath);

    final str = uriOrPath.toString().trim();
    if (str.startsWith('http://') || str.startsWith('https://')) {
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
    if (str.startsWith('asset://') ||
        str.startsWith('assets://') ||
        str.startsWith('flutter-asset://') ||
        str.startsWith('assets/')) {
      final clean = str.replaceFirst(
        RegExp(r'^(flutter-)?asset(s)?:///?', caseSensitive: false),
        '',
      );
      final normalized =
          clean.startsWith('assets/') ? clean : 'assets/$clean';
      return AssetAudioSource(normalized);
    }
    if (str.startsWith('file://')) {
      return FileAudioSource(FileByteProvider.normalizeFileUriOrPath(str));
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
  String toString() => 'FileAudioSource($filePath)';
}

/// An asset packaged in the Flutter app bundle.
class AssetAudioSource extends AudioSource {
  final String assetKey;
  final String? package;
  const AssetAudioSource(this.assetKey, {this.package});

  @override
  String toString() => package != null
      ? 'AssetAudioSource(packages/$package/$assetKey)'
      : 'AssetAudioSource($assetKey)';
}

/// Audio data loaded directly from an in-memory byte buffer (RAM).
class MemoryAudioSource extends AudioSource {
  final Uint8List bytes;
  const MemoryAudioSource(this.bytes);

  @override
  String toString() => 'MemoryAudioSource(${bytes.lengthInBytes} bytes)';
}

/// A remote audio source (progressive file or live stream) accessed via HTTP/HTTPS.
///
/// Live streams are automatically detected from HTTP headers (`Content-Length`,
/// `Transfer-Encoding: chunked`, `icy-metaint`, `icy-name`, `icy-br`) even when
/// [isLive] is `false`.
class NetworkAudioSource extends AudioSource {
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

/// A custom audio source driven by a user-supplied [AudioByteProvider].
class CustomAudioSource extends AudioSource {
  final AudioByteProvider provider;
  const CustomAudioSource(this.provider);

  @override
  String toString() => 'CustomAudioSource(${provider.sourceId})';
}

