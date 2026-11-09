import 'dart:typed_data';

/// Encapsulates raw metadata bytes extracted from an audio track
/// (e.g. ID3v2, Vorbis Comments, FLAC METADATA_BLOCK_PICTURE, MP4 moov/udta atoms).
///
/// Designed to encapsulate raw metadata bytes cleanly without polluting the top-level
/// analysis model, paving the way for future parsed tags without breaking existing code.
class AudioMetadata {
  /// Raw metadata bytes extracted from the container/file headers.
  final Uint8List bytes;

  /// Creates an immutable [AudioMetadata] container.
  const AudioMetadata({required this.bytes});

  /// Length of the metadata byte buffer.
  int get length => bytes.length;

  /// Whether the metadata byte buffer is empty.
  bool get isEmpty => bytes.isEmpty;

  /// Whether the metadata byte buffer is non-empty.
  bool get isNotEmpty => bytes.isNotEmpty;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioMetadata &&
          runtimeType == other.runtimeType &&
          _bytesEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'AudioMetadata(${bytes.length} bytes)';

  static bool _bytesEquals(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
