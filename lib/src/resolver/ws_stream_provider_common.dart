/// Shared FIFO buffering and base stream adapter for WebSocket audio sources.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import '../api/logger.dart';
import '../loader/custom_byte_provider.dart';

/// Next internal managed stream identifier allocated by
/// [allocateManagedStreamId].
int _nextWsStreamId = 0x40000000;

/// Allocates a collision-free internal stream ID (`>= 0x40000000`) for
/// managed streaming providers such as WebSocket audio streams.
///
/// Wraps back to `0x40000000` once the range approaches `0x7FFE0000`.
int allocateManagedStreamId() {
  final id = _nextWsStreamId;
  _nextWsStreamId = id >= 0x7FFE0000 ? 0x40000000 : id + 1;
  MapLogger.debug('Allocated managed WebSocket streamId=$id.');
  return id;
}

/// Bounded FIFO byte ring shared by IO and Web WebSocket audio stream bridges.
///
/// Buffers incoming binary chunks up to [maxBufferedBytes] and evicts the
/// oldest unread chunks when a slow consumer falls behind.
class WebSocketFifoBuffer {
  /// Maximum unread buffered bytes before oldest live frames are dropped.
  final int maxBufferedBytes;

  /// Queued raw byte chunks waiting to be consumed by [readUpTo].
  final Queue<Uint8List> _chunks = Queue<Uint8List>();

  /// Total unread bytes currently stored across [_chunks].
  int _queuedBytes = 0;

  /// Byte offset within the head chunk of [_chunks] already consumed.
  int _frontOffset = 0;

  /// Whether [markClosed] has terminated this buffer.
  bool _closed = false;

  /// Deferred terminal error surfaced once all buffered bytes are drained.
  Object? _terminalError;

  /// Pending reader completer awakened when new data arrives or EOF occurs.
  Completer<void>? _waiter;

  /// Creates a bounded FIFO buffer with capacity [maxBufferedBytes] (defaulting
  /// to 8 MiB).
  WebSocketFifoBuffer({this.maxBufferedBytes = 8 * 1024 * 1024});

  /// Whether the stream has been closed via [markClosed].
  bool get isClosed => _closed;

  /// Total unread bytes currently queued in this FIFO buffer.
  int get queuedBytes => _queuedBytes;

  /// Enqueues incoming binary [bytes] into the FIFO and wakes any reader.
  ///
  /// Drops the oldest queued chunks when adding [bytes] would exceed
  /// [maxBufferedBytes]. Ignores empty chunks or writes after [isClosed] is
  /// `true`.
  void push(Uint8List bytes) {
    if (_closed || bytes.isEmpty) return;

    while (
        _queuedBytes + bytes.length > maxBufferedBytes && _chunks.isNotEmpty) {
      final dropped = _chunks.removeFirst();
      final droppedUnread = dropped.length - _frontOffset;
      _queuedBytes -= droppedUnread;
      _frontOffset = 0;
      MapLogger.verbose(
        'WebSocketFifoBuffer dropped $droppedUnread unread bytes due to '
        'backpressure (maxBufferedBytes=$maxBufferedBytes).',
      );
    }

    _chunks.addLast(bytes);
    _queuedBytes += bytes.length;
    _wakeWaiter();
  }

  /// Marks end-of-stream with an optional terminal [error] and wakes any
  /// blocked reader.
  ///
  /// Subsequent calls after the first transition are ignored.
  void markClosed([Object? error]) {
    if (_closed) return;
    _closed = true;
    _terminalError = error;
    if (error != null) {
      MapLogger.warn(
        'WebSocketFifoBuffer closed with error (queuedBytes=$_queuedBytes): '
        '$error',
      );
    } else {
      MapLogger.debug(
        'WebSocketFifoBuffer marked closed (queuedBytes=$_queuedBytes).',
      );
    }
    _wakeWaiter();
  }

  /// Completes and clears [_waiter] if a reader is currently suspended.
  void _wakeWaiter() {
    final w = _waiter;
    if (w != null && !w.isCompleted) {
      _waiter = null;
      w.complete();
    }
  }

  /// Awaits at least one buffered byte or EOF and drains up to [maxBytes].
  ///
  /// Returns an empty [Uint8List] when [maxBytes] is `<= 0` or at clean EOF.
  /// Rethrows the deferred terminal error once all buffered bytes are read.
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
        MapLogger.error('WebSocketFifoBuffer surfacing terminal error: $err');
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
  /// The internal stream identifier registered with the native player engine.
  @override
  final int streamId;

  /// Bounded FIFO queue storing incoming WebSocket audio frame bytes.
  final WebSocketFifoBuffer fifo;

  /// Creates a [BaseWebSocketByteProvider] identified by [streamId].
  BaseWebSocketByteProvider(this.streamId) : fifo = WebSocketFifoBuffer();

  /// Total stream length in bytes, always `null` for unbounded live streams.
  @override
  int? get totalBytes => null;

  /// Whether seeking is supported, always `false` for live WebSocket streams.
  @override
  bool get isSeekable => false;

  /// Reads up to [length] sequential bytes from [fifo], ignoring [offset].
  @override
  Future<Uint8List> readBytes(int offset, int length) async {
    return fifo.readUpTo(length);
  }
}
