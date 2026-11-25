import 'dart:typed_data';

/// Contract for asynchronous pull-based custom byte streams in Dart.
///
/// Implement this interface to back audio sources such as DRM-protected
/// streams, encrypted media containers, or tokenized remote storage.
abstract class CustomByteProvider {
  /// Returns the stream identifier matching the native Rust stream ID.
  int get streamId;

  /// Returns the total size of the stream in bytes, or `null` when unknown or
  /// unbounded.
  int? get totalBytes;

  /// Whether random-access seeking is supported by this byte stream.
  bool get isSeekable;

  /// Asynchronously fetches up to [length] bytes starting at byte [offset].
  ///
  /// Returning fewer than [length] bytes or an empty [Uint8List] signals
  /// end-of-stream to the native decoder.
  Future<Uint8List> readBytes(int offset, int length);

  /// Closes this provider and releases any underlying connections or resources.
  Future<void> close();
}
