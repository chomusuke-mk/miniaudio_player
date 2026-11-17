import 'dart:js_interop';
import 'dart:typed_data';

import 'tap_buffer_stub.dart';

export 'tap_buffer_stub.dart' show PlatformTapBuffer;

@JS('wasm_bindgen.wasm_poll_audio_tap_bytes')
external int _wasmPollAudioTapBytes(int tapId, JSUint8Array dst, int maxFrames);

@JS('wasm_bindgen.wasm_get_audio_tap_dropped_frames')
external double _wasmGetAudioTapDroppedFrames(int tapId);

@JS('wasm_bindgen.wasm_close_pull_audio_tap')
external void _wasmClosePullAudioTap(int tapId);

final class _WebPlatformTapBuffer implements PlatformTapBuffer {
  static final Finalizer<int> _gcFinalizer = Finalizer<int>((id) {
    try {
      _wasmClosePullAudioTap(id);
    } catch (_) {}
  });

  @override
  final int tapId;
  final JSUint8Array _jsBytes;

  bool _closed = false;
  int _lastKnownDropped = 0;

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
  }

  @override
  bool get isClosed => _closed;

  @override
  int get lastKnownDropped => _lastKnownDropped;

  @override
  int get droppedFrames {
    if (_closed) return _lastKnownDropped;
    final current = _wasmGetAudioTapDroppedFrames(tapId).toInt();
    _lastKnownDropped = current;
    return current;
  }

  @override
  int pollFrames(int maxFrames) {
    if (_closed || maxFrames <= 0) return 0;
    final frames = _wasmPollAudioTapBytes(tapId, _jsBytes, maxFrames);
    _lastKnownDropped = _wasmGetAudioTapDroppedFrames(tapId).toInt();
    return frames;
  }

  @override
  Uint8List bytesSublistView(int byteLen) {
    final dartBytes = _jsBytes.toDart;
    final safeLen = byteLen.clamp(0, dartBytes.length);
    return Uint8List.sublistView(dartBytes, 0, safeLen);
  }

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

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _gcFinalizer.detach(this);
    try {
      _wasmClosePullAudioTap(tapId);
    } catch (_) {}
  }
}

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
