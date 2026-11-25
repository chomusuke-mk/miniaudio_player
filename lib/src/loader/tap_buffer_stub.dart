import 'dart:typed_data';

import '../api/logger.dart';

/// Platform-specific backing buffer contract for a pull-based audio tap.
///
/// Implementations maintain a reusable native or WebAssembly buffer so callers
/// can poll PCM frames with zero per-call heap allocations.
abstract interface class PlatformTapBuffer {
  /// Returns the native engine identifier assigned to this pull tap.
  int get tapId;

  /// Whether this tap buffer has been closed.
  bool get isClosed;

  /// Returns the cached cumulative dropped-frame count from the last query or
  /// poll.
  int get lastKnownDropped;

  /// Queries the cumulative number of frames dropped by this tap due to buffer
  /// overflow.
  int get droppedFrames;

  /// Polls up to [maxFrames] PCM frames from the engine into the internal
  /// reusable buffer and returns the number of frames copied.
  int pollFrames(int maxFrames);

  /// Returns a [Uint8List] sublist view covering the first [byteLen] bytes of
  /// the internal buffer.
  Uint8List bytesSublistView(int byteLen);

  /// Returns a [Float32List] sublist view covering the first [sampleCount]
  /// float32 samples of the internal buffer.
  Float32List float32SublistView(int sampleCount);

  /// Returns an [Int16List] sublist view covering the first [sampleCount]
  /// signed 16-bit PCM samples of the internal buffer.
  Int16List int16SublistView(int sampleCount);

  /// Closes this pull tap handle and releases its associated native or
  /// WebAssembly subscription.
  void close();
}

/// Creates a [PlatformTapBuffer] for the active platform target.
///
/// Allocates backing storage sized for [capacityFrames] frames of
/// [bytesPerFrame] bytes each, bound to the engine handle identified by
/// [tapId].
PlatformTapBuffer createPlatformTapBuffer({
  required int tapId,
  required int bytesPerFrame,
  required int capacityFrames,
}) {
  MapLogger.error(
    'AudioTapBuffer is unsupported on this stub platform target (tapId=$tapId).',
  );
  throw UnsupportedError('AudioTapBuffer is not supported on this platform.');
}
