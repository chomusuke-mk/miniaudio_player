import 'dart:typed_data';

import '../loader/custom_byte_provider.dart';

/// Represents a source of audio playable by `MiniaudioPlayer` or `MiniaudioEngine`.
///
/// Designed with zero redundancy:
/// - [AudioSource.new]: Unified constructor accepting either a [String] (local file path,
///   remote HTTP/HTTPS URL, HLS m3u8 stream) or raw audio bytes ([Uint8List] / `List<int>`).
///   Rust automatically determines whether a String is a local file or network stream.
/// - [AudioSource.custom]: Constructor for custom byte streams in Dart (DRM, encrypted
///   decryption, tokenized storage) via [CustomByteProvider].
sealed class AudioSource {
  const AudioSource._();

  /// Creates an audio source from a [String] (local path, URL, HLS stream)
  /// or in-memory audio bytes ([Uint8List] / `List<int>`).
  ///
  /// Optional [headers] are passed to the HTTP/HLS request when [source] is a remote URL.
  factory AudioSource(
    Object source, {
    Map<String, String>? headers,
  }) {
    if (source is AudioSource) {
      return source;
    }
    if (source is Uri) {
      if (source.data != null) {
        return MemoryAudioSource(source.data!.contentAsBytes());
      }
      return UriAudioSource(source.toString(), headers: headers);
    }
    if (source is String) {
      final str = source.trim();
      if (str.toLowerCase().startsWith('data:')) {
        try {
          final uriData = UriData.parse(str);
          return MemoryAudioSource(uriData.contentAsBytes());
        } catch (_) {
          return UriAudioSource(str, headers: headers);
        }
      }
      return UriAudioSource(str, headers: headers);
    }
    if (source is Uint8List) {
      return MemoryAudioSource(source);
    }
    if (source is List<int>) {
      return MemoryAudioSource(Uint8List.fromList(source));
    }
    throw ArgumentError.value(
      source,
      'source',
      'AudioSource requires a String (path or URL) or Uint8List (audio bytes), got ${source.runtimeType}',
    );
  }

  /// Creates a custom audio source driven by a user-supplied [CustomByteProvider]
  /// for custom DRM or encrypted byte decryption.
  const factory AudioSource.custom(CustomByteProvider provider) =
      CustomAudioSource;
}

/// An audio source represented by a string path or URL handled natively in Rust.
final class UriAudioSource extends AudioSource {
  /// The local file path or remote URL.
  final String sourceString;

  /// Optional HTTP headers for network/HLS sources.
  final Map<String, String>? headers;

  const UriAudioSource(this.sourceString, {this.headers}) : super._();

  @override
  String toString() => 'AudioSource($sourceString)';
}

/// An in-memory audio source backed by raw bytes in RAM.
final class MemoryAudioSource extends AudioSource {
  /// Raw audio file bytes.
  final Uint8List bytes;

  const MemoryAudioSource(this.bytes) : super._();

  @override
  String toString() => 'AudioSource(${bytes.lengthInBytes} bytes)';
}

/// A custom audio source backed by a Dart [CustomByteProvider] (e.g. for DRM decryption).
final class CustomAudioSource extends AudioSource {
  /// The underlying custom byte provider.
  final CustomByteProvider provider;

  const CustomAudioSource(this.provider) : super._();

  @override
  String toString() => 'AudioSource.custom(streamId: ${provider.streamId})';
}
