import 'dart:async';
import 'dart:typed_data';

/// Extensible random-access byte sink interface for cross-platform live recording.
///
/// Implement this interface directly (e.g. adapting `package:file`, IndexedDB,
/// custom encryption streams, or network staging) and pass it via
/// `player.action.startRecording(buffer: myBuffer)`.
///
/// Every recording session guarantees strict FIFO ordering of [write], followed
/// by [writeAt] RIFF header back-patching, [flush], and [close] upon completion.
abstract interface class RecordingByteBuffer {
  /// Appends [bytes] sequentially to the end of the recording stream.
  FutureOr<void> write(Uint8List bytes);

  /// Overwrites bytes starting at byte [offset] (used to finalize RIFF WAV headers at `stopRecording()`).
  FutureOr<void> writeAt(int offset, Uint8List bytes);

  /// Flushes any pending buffered bytes to the underlying sink.
  FutureOr<void> flush();

  /// Releases resources or finalizes the sink when recording finishes.
  FutureOr<void> close();

  /// Optional display/destination path reported in [RecordingResult.path].
  String? get path;

  /// Current logical byte length written to this sink.
  int get lengthInBytes;

  /// Creates the built-in chunked in-memory WAV recording buffer.
  factory RecordingByteBuffer.memory({
    String? path,
    int chunkSizeBytes,
  }) = MemoryRecordingBuffer;
}

/// Chunked in-memory [RecordingByteBuffer] with amortized $O(1)$ append performance.
///
/// Stores audio in fixed-size blocks (default 64 KiB) to avoid large contiguous
/// array reallocations while recording, supporting random-access [writeAt]
/// patching for WAV RIFF headers on all platforms (including Web, Desktop, and Mobile).
class MemoryRecordingBuffer implements RecordingByteBuffer {
  /// Default internal chunk capacity (64 KiB).
  static const int defaultChunkSizeBytes = 65536;

  final String? _path;
  final int _chunkSize;
  final List<Uint8List> _chunks = [];
  int _length = 0;
  bool _closed = false;

  /// Creates an in-memory [MemoryRecordingBuffer] with an optional display [path].
  MemoryRecordingBuffer({
    String? path,
    int chunkSizeBytes = defaultChunkSizeBytes,
  })  : _path = path,
        _chunkSize = chunkSizeBytes > 0
            ? chunkSizeBytes
            : throw ArgumentError.value(
                chunkSizeBytes,
                'chunkSizeBytes',
                'chunkSizeBytes must be > 0',
              );

  @override
  String? get path => _path;

  @override
  int get lengthInBytes => _length;

  /// Whether [close] has been invoked on this buffer.
  bool get isClosed => _closed;

  /// Allocates/returns zero-filled chunks covering at least [minLength] bytes.
  void _ensureCapacity(int minLength) {
    final neededChunks = (minLength + _chunkSize - 1) ~/ _chunkSize;
    while (_chunks.length < neededChunks) {
      _chunks.add(Uint8List(_chunkSize));
    }
  }

  @override
  void write(Uint8List bytes) {
    if (bytes.isEmpty) return;
    _writeRange(_length, bytes);
  }

  @override
  void writeAt(int offset, Uint8List bytes) {
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Offset cannot be negative');
    }
    if (bytes.isEmpty) return;
    _writeRange(offset, bytes);
  }

  void _writeRange(int startOffset, Uint8List bytes) {
    final endOffset = startOffset + bytes.length;
    _ensureCapacity(endOffset);

    var srcPos = 0;
    var dstPos = startOffset;
    while (srcPos < bytes.length) {
      final chunkIdx = dstPos ~/ _chunkSize;
      final chunkOff = dstPos % _chunkSize;
      final remainingInChunk = _chunkSize - chunkOff;
      final remainingSrc = bytes.length - srcPos;
      final count =
          remainingInChunk < remainingSrc ? remainingInChunk : remainingSrc;

      _chunks[chunkIdx].setRange(chunkOff, chunkOff + count, bytes, srcPos);
      srcPos += count;
      dstPos += count;
    }

    if (endOffset > _length) {
      _length = endOffset;
    }
  }

  /// Unmodifiable read-only snapshot views over the populated slices of internal chunks.
  List<Uint8List> get chunks {
    if (_length == 0) return const [];
    final out = <Uint8List>[];
    var remaining = _length;
    for (final chunk in _chunks) {
      if (remaining <= 0) break;
      final used = remaining < chunk.length ? remaining : chunk.length;
      out.add(Uint8List.sublistView(chunk, 0, used).asUnmodifiableView());
      remaining -= used;
    }
    return List<Uint8List>.unmodifiable(out);
  }

  /// Materializes the entire recorded payload into a single contiguous [Uint8List].
  Uint8List toBytes() {
    if (_length == 0) return Uint8List(0);
    final result = Uint8List(_length);
    var offset = 0;
    var remaining = _length;
    for (final chunk in _chunks) {
      if (remaining <= 0) break;
      final used = remaining < chunk.length ? remaining : chunk.length;
      result.setRange(offset, offset + used, chunk);
      offset += used;
      remaining -= used;
    }
    return result;
  }

  /// Materializes all bytes into a contiguous [Uint8List] and releases internal chunks.
  Uint8List takeBytes() {
    final result = toBytes();
    clear();
    return result;
  }

  /// Clears all stored chunks and resets [lengthInBytes] to `0`.
  void clear() {
    _chunks.clear();
    _length = 0;
  }

  @override
  void flush() {}

  @override
  void close() {
    _closed = true;
  }
}
