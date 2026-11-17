import 'dart:typed_data';

abstract interface class PlatformTapBuffer {
  int get tapId;
  bool get isClosed;
  int get lastKnownDropped;
  int get droppedFrames;

  int pollFrames(int maxFrames);
  Uint8List bytesSublistView(int byteLen);
  Float32List float32SublistView(int sampleCount);
  Int16List int16SublistView(int sampleCount);
  void close();
}

PlatformTapBuffer createPlatformTapBuffer({
  required int tapId,
  required int bytesPerFrame,
  required int capacityFrames,
}) {
  throw UnsupportedError('AudioTapBuffer is not supported on this platform.');
}
