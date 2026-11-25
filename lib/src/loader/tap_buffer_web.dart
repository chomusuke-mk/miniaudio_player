import 'dart:js_interop';
import 'dart:typed_data';

import '../api/logger.dart';
import 'tap_buffer_stub.dart';

export 'tap_buffer_stub.dart' show PlatformTapBuffer;

/// Polls up to [maxFrames] PCM frames for [tapId] into the WebAssembly-backed
/// [dst] byte array and returns the number of frames copied.
@JS('wasm_bindgen.wasm_poll_audio_tap_bytes')
external int _wasmPollAudioTapBytes(int tapId, JSUint8Array dst, int maxFrames);

/// Returns the cumulative number of dropped frames reported by WebAssembly for
/// [tapId].
@JS('wasm_bindgen.wasm_get_audio_tap_dropped_frames')
external double _wasmGetAudioTapDroppedFrames(int tapId);

/// Closes the pull tap identified by [tapId] in the WebAssembly engine.
@JS('wasm_bindgen.wasm_close_pull_audio_tap')
external void _wasmClosePullAudioTap(int tapId);

/// WebAssembly implementation of [PlatformTapBuffer] backed by a reusable
/// [JSUint8Array] transfer buffer.
final class _WebPlatformTapBuffer implements PlatformTapBuffer {
  /// GC finalizer that closes unclosed pull tap handles when collected.
  static final Finalizer<int> _gcFinalizer = Finalizer<int>((id) {
    try {
      _wasmClosePullAudioTap(id);
    } catch (e) {
      MapLogger.debug('GC finalizer failed to close Web pull tap $id: $e');
    }
  });

  /// Native WebAssembly engine identifier assigned to this pull tap.
  @override
  final int tapId;

  /// Reusable JavaScript byte array populated by [_wasmPollAudioTapBytes].
  final JSUint8Array _jsBytes;

  /// Whether [close] has already been called.
  bool _closed = false;

  /// Most recently observed dropped-frame total.
  int _lastKnownDropped = 0;

  /// Allocates a Web pull tap buffer bound to [tapId] sized for
  /// [capacityFrames] frames of [bytesPerFrame] bytes each.
  _WebPlatformTapBuffer({
    required this.tapId,
    required int bytesPerFrame,
    required int capacityFrames,
  }) : _jsBytes = JSUint8Array.withLength(
          (capacityFrames * bytesPerFrame).clamp(1, 1 << 28),
        ) {
    if (tapId > 0) {
      _gcFinalizer.attach(this, tapId, detach: this);
    }
    MapLogger.debug(
      'Created Web PlatformTapBuffer(tapId=$tapId, byteLen=${(capacityFrames * bytesPerFrame).clamp(1, 1 << 28)}).',
    );
  }

  /// Whether this tap buffer has been closed.
  @override
  bool get isClosed => _closed;

  /// Returns the cached cumulative dropped-frame count from the last query or
  /// poll.
  @override
  int get lastKnownDropped => _lastKnownDropped;

  /// Queries the WebAssembly engine for cumulative dropped frames on [tapId].
  @override
  int get droppedFrames {
    if (_closed) return _lastKnownDropped;
    final current = _wasmGetAudioTapDroppedFrames(tapId).toInt();
    _lastKnownDropped = current;
    return current;
  }

  /// Polls up to [maxFrames] PCM frames from WebAssembly into [_jsBytes] and
  /// returns the number of frames copied.
  @override
  int pollFrames(int maxFrames) {
    if (_closed || maxFrames <= 0) return 0;
    final frames = _wasmPollAudioTapBytes(tapId, _jsBytes, maxFrames);
    _lastKnownDropped = _wasmGetAudioTapDroppedFrames(tapId).toInt();
    return frames;
  }

  /// Returns a [Uint8List] sublist view covering the first [byteLen] bytes of
  /// [_jsBytes].
  @override
  Uint8List bytesSublistView(int byteLen) {
    final dartBytes = _jsBytes.toDart;
    final safeLen = byteLen.clamp(0, dartBytes.length);
    return Uint8List.sublistView(dartBytes, 0, safeLen);
  }

  /// Returns a [Float32List] sublist view covering the first [sampleCount]
  /// samples of [_jsBytes].
  @override
  Float32List float32SublistView(int sampleCount) {
    final dartBytes = _jsBytes.toDart;
    final view = dartBytes.buffer.asFloat32List(
      dartBytes.offsetInBytes,
      dartBytes.lengthInBytes ~/ 4,
    );
    final safeLen = sampleCount.clamp(0, view.length);
    return Float32List.sublistView(view, 0, safeLen);
  }

  /// Returns an [Int16List] sublist view covering the first [sampleCount]
  /// samples of [_jsBytes].
  @override
  Int16List int16SublistView(int sampleCount) {
    final dartBytes = _jsBytes.toDart;
    final view = dartBytes.buffer.asInt16List(
      dartBytes.offsetInBytes,
      dartBytes.lengthInBytes ~/ 2,
    );
    final safeLen = sampleCount.clamp(0, view.length);
    return Int16List.sublistView(view, 0, safeLen);
  }

  /// Detaches the GC finalizer and closes the WebAssembly pull tap [tapId].
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _gcFinalizer.detach(this);
    try {
      _wasmClosePullAudioTap(tapId);
      MapLogger.debug('Closed Web PlatformTapBuffer(tapId=$tapId).');
    } catch (e) {
      MapLogger.warn('Failed to close Web pull tap $tapId: $e');
    }
  }
}

/// Creates a WebAssembly-backed [PlatformTapBuffer] bound to [tapId] with
/// backing storage for [capacityFrames] frames of [bytesPerFrame] bytes each.
PlatformTapBuffer createPlatformTapBuffer({
  required int tapId,
  required int bytesPerFrame,
  required int capacityFrames,
}) {
  return _WebPlatformTapBuffer(
    tapId: tapId,
    bytesPerFrame: bytesPerFrame,
    capacityFrames: capacityFrames,
  );
}
