import 'dart:typed_data';

/// Represents a source of audio playable by `MiniaudioPlayer`.
sealed class AudioSource {
  const AudioSource();

  /// Creates an audio source backed by a local filesystem file path.
  const factory AudioSource.file(String filePath) = FileAudioSource;

  /// Creates an audio source loaded directly from Flutter bundle assets without disk I/O.
  const factory AudioSource.asset(String assetKey, {String? package}) = AssetAudioSource;

  /// Creates an audio source backed by an in-memory byte buffer (RAM).
  const factory AudioSource.memory(Uint8List bytes) = MemoryAudioSource;

  /// Creates an audio source from a remote HTTP or HTTPS URL (S3 bucket, CDN, etc.).
  const factory AudioSource.network(
    Uri uri, {
    Map<String, String>? headers,
    bool enableCache,
    Duration bufferAhead,
  }) = NetworkAudioSource;

  /// Creates an audio source for a continuous live web stream (Internet Radio, Icecast).
  const factory AudioSource.liveStream(
    Uri uri, {
    Map<String, String>? headers,
    Duration jitterBuffer,
  }) = LiveStreamAudioSource;

  /// Auto-resolves a URI string or [Uri] into the appropriate [AudioSource].
  factory AudioSource.uri(dynamic uriOrPath) {
    if (uriOrPath is AudioSource) return uriOrPath;
    final str = uriOrPath.toString().trim();
    if (str.startsWith('asset://') || str.startsWith('assets/')) {
      final clean = str.replaceFirst(RegExp(r'^asset(s)?://'), 'assets/');
      return AssetAudioSource(clean);
    } else if (str.startsWith('http://') || str.startsWith('https://')) {
      return NetworkAudioSource(Uri.parse(str));
    } else if (str.startsWith('file://')) {
      return FileAudioSource(Uri.parse(str).toFilePath());
    } else {
      return FileAudioSource(str);
    }
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
  String toString() =>
      package != null ? 'AssetAudioSource(packages/$package/$assetKey)' : 'AssetAudioSource($assetKey)';
}

/// Audio data loaded directly from an in-memory byte buffer (RAM).
class MemoryAudioSource extends AudioSource {
  final Uint8List bytes;
  const MemoryAudioSource(this.bytes);

  @override
  String toString() => 'MemoryAudioSource(${bytes.lengthInBytes} bytes)';
}

/// A remote audio file accessed via HTTP/HTTPS.
class NetworkAudioSource extends AudioSource {
  final Uri uri;
  final Map<String, String>? headers;
  final bool enableCache;
  final Duration bufferAhead;

  /// URL alias for [uri].
  Uri get url => uri;

  /// Always false for progressive files.
  bool get isLive => false;

  const NetworkAudioSource(
    this.uri, {
    this.headers,
    this.enableCache = true,
    this.bufferAhead = const Duration(seconds: 30),
  });

  @override
  String toString() => 'NetworkAudioSource($uri)';
}

/// A live audio stream (Internet Radio, Icecast, etc.) with a sliding jitter buffer.
class LiveStreamAudioSource extends AudioSource {
  final Uri uri;
  final Map<String, String>? headers;
  final Duration jitterBuffer;

  /// URL alias for [uri].
  Uri get url => uri;

  /// Always true for live streams.
  bool get isLive => true;

  const LiveStreamAudioSource(
    this.uri, {
    this.headers,
    this.jitterBuffer = const Duration(seconds: 5),
  });

  @override
  String toString() => 'LiveStreamAudioSource($uri)';
}
