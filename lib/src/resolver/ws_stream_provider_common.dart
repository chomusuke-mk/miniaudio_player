import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../loader/custom_byte_provider.dart';

int _nextWsStreamId = 0x40000000;

/// Allocates a collision-free internal stream ID (`>= 0x40000000`) for
/// managed streaming providers such as WebSocket audio streams.
int allocateManagedStreamId() {
  final id = _nextWsStreamId;
  _nextWsStreamId = id >= 0x7FFE0000 ? 0x40000000 : id + 1;
  return id;
}

/// Bounded FIFO byte ring shared by IO and Web WebSocket audio stream bridges.
class WebSocketFifoBuffer {
  /// Maximum unread buffered bytes (~8 MB) before oldest live frames drop.
  final int maxBufferedBytes;

  final Queue<Uint8List> _chunks = Queue<Uint8List>();
  int _queuedBytes = 0;
  int _frontOffset = 0;
  bool _closed = false;
  Object? _terminalError;
  Completer<void>? _waiter;

  WebSocketFifoBuffer({this.maxBufferedBytes = 8 * 1024 * 1024});

  bool get isClosed => _closed;
  int get queuedBytes => _queuedBytes;

  /// Enqueues incoming binary frame bytes into the FIFO and wakes any reader.
  void push(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;

    while (_queuedBytes + bytes.length > maxBufferedBytes && _chunks.isNotEmpty) {
      final dropped = _chunks.removeFirst();
      _queuedBytes -= dropped.length - _frontOffset;
      _frontOffset = 0;
    }

    _chunks.addLast(bytes);
    _queuedBytes += bytes.length;
    _wakeWaiter();
  }

  /// Marks end-of-stream (or failure) and wakes any blocked reader.
  void markClosed([Object? error]) {
    if (_closed) return;
    _closed = true;
    _terminalError = error;
    _wakeWaiter();
  }

  void _wakeWaiter() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  /// Awaits at least one buffered byte (or EOF) and drains up to [maxBytes].
  Future<Uint8List> readUpTo(int maxBytes) async {
    if (maxBytes <= 0) return Uint8List(0);

    while (_chunks.isEmpty && !_closed) {
      final w = _waiter ??= Completer<void>();
      await w.future;
    }

    if (_chunks.isEmpty) {
      if (_terminalError != null) {
        final err = _terminalError!;
        _terminalError = null;
        throw err;
      }
      return Uint8List(0);
    }

    final first = _chunks.first;
    final firstAvail = first.length - _frontOffset;
    if (firstAvail >= maxBytes) {
      final slice = Uint8List.fromList(
        Uint8List.sublistView(first, _frontOffset, _frontOffset + maxBytes),
      );
      _frontOffset += maxBytes;
      _queuedBytes -= maxBytes;
      if (_frontOffset >= first.length) {
        _chunks.removeFirst();
        _frontOffset = 0;
      }
      return slice;
    }

    final takeTotal = maxBytes < _queuedBytes ? maxBytes : _queuedBytes;
    final out = Uint8List(takeTotal);
    var written = 0;
    while (written < takeTotal && _chunks.isNotEmpty) {
      final head = _chunks.first;
      final avail = head.length - _frontOffset;
      final need = takeTotal - written;
      final copyCount = avail <= need ? avail : need;
      out.setRange(written, written + copyCount, head, _frontOffset);
      written += copyCount;
      _frontOffset += copyCount;
      _queuedBytes -= copyCount;
      if (_frontOffset >= head.length) {
        _chunks.removeFirst();
        _frontOffset = 0;
      }
    }
    return out;
  }
}

/// Abstract base [CustomByteProvider] adapter backed by [WebSocketFifoBuffer].
abstract class BaseWebSocketByteProvider extends CustomByteProvider {
  @override
  final int streamId;

  final WebSocketFifoBuffer fifo;

  BaseWebSocketByteProvider(this.streamId) : fifo = WebSocketFifoBuffer();

  @override
  int? get totalBytes => null;

  @override
  bool get isSeekable => false;

  @override
  Future<Uint8List> readBytes(int offset, int length) async {
    return fifo.readUpTo(length);
  }
}
