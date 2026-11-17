import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'platform_loader_io.dart';
import 'tap_buffer_stub.dart';

export 'tap_buffer_stub.dart' show PlatformTapBuffer;

typedef _AllocBufNative = ffi.Pointer<ffi.Void> Function(ffi.Size byteLen);
typedef _AllocBufDart = ffi.Pointer<ffi.Void> Function(int byteLen);

typedef _BufPtrNative = ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Void> buf);
typedef _BufPtrDart = ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Void> buf);

typedef _FinalizerCbNative = ffi.Pointer<ffi.NativeFinalizerFunction> Function();
typedef _FinalizerCbDart = ffi.Pointer<ffi.NativeFinalizerFunction> Function();

typedef _PollBytesNative = ffi.Uint32 Function(
  ffi.Uint32 tapId,
  ffi.Pointer<ffi.Uint8> dst,
  ffi.Size byteLen,
  ffi.Uint32 maxFrames,
  ffi.Pointer<ffi.Uint64> outDropped,
);
typedef _PollBytesDart = int Function(
  int tapId,
  ffi.Pointer<ffi.Uint8> dst,
  int byteLen,
  int maxFrames,
  ffi.Pointer<ffi.Uint64> outDropped,
);

typedef _GetDroppedNative = ffi.Uint64 Function(ffi.Uint32 tapId);
typedef _GetDroppedDart = int Function(int tapId);

typedef _ClosePullNative = ffi.Void Function(ffi.Uint32 tapId);
typedef _ClosePullDart = void Function(int tapId);

final class _TapFfiBindings {
  final _AllocBufDart allocBuffer;
  final _BufPtrDart bufferDataPtr;
  final _PollBytesDart pollBytes;
  final _GetDroppedDart getDropped;
  final _ClosePullDart closePull;
  final ffi.NativeFinalizer bufferFinalizer;
  final ffi.NativeFinalizer pullFinalizer;

  _TapFfiBindings(ffi.DynamicLibrary lib)
      : allocBuffer = lib.lookupFunction<_AllocBufNative, _AllocBufDart>(
          'map_tap_alloc_buffer',
        ),
        bufferDataPtr = lib.lookupFunction<_BufPtrNative, _BufPtrDart>(
          'map_tap_buffer_data_ptr',
        ),
        pollBytes = lib.lookupFunction<_PollBytesNative, _PollBytesDart>(
          'map_tap_poll_bytes',
        ),
        getDropped = lib.lookupFunction<_GetDroppedNative, _GetDroppedDart>(
          'map_tap_get_dropped',
        ),
        closePull = lib.lookupFunction<_ClosePullNative, _ClosePullDart>(
          'map_tap_close_pull',
        ),
        bufferFinalizer = ffi.NativeFinalizer(
          lib.lookupFunction<_FinalizerCbNative, _FinalizerCbDart>(
            'map_tap_free_buffer_callback',
          )(),
        ),
        pullFinalizer = ffi.NativeFinalizer(
          lib.lookupFunction<_FinalizerCbNative, _FinalizerCbDart>(
            'map_tap_close_pull_callback',
          )(),
        );
}

_TapFfiBindings? _cachedBindings;

_TapFfiBindings _resolveBindings() {
  final existing = _cachedBindings;
  if (existing != null) return existing;

  final lib = loadedNativeDynamicLibrary ?? ffi.DynamicLibrary.process();
  final resolved = _TapFfiBindings(lib);
  _cachedBindings = resolved;
  return resolved;
}

final class _IoPlatformTapBuffer implements PlatformTapBuffer, ffi.Finalizable {
  final _TapFfiBindings _bindings;
  @override
  final int tapId;
  final int _byteLen;
  final ffi.Pointer<ffi.Void> _nativeBuf;
  late final ffi.Pointer<ffi.Uint8> _dataPtr;
  final ffi.Pointer<ffi.Void> _droppedBuf;
  late final ffi.Pointer<ffi.Uint64> _droppedPtr;

  late final Uint8List _bytesView;
  late final Float32List _f32View;
  late final Int16List _i16View;

  bool _closed = false;
  int _lastKnownDropped = 0;

  _IoPlatformTapBuffer({
    required _TapFfiBindings bindings,
    required this.tapId,
    required int bytesPerFrame,
    required int capacityFrames,
  })  : _bindings = bindings,
        _byteLen = (capacityFrames * bytesPerFrame).clamp(1, 1 << 30),
        _nativeBuf = bindings.allocBuffer((capacityFrames * bytesPerFrame).clamp(1, 1 << 30)),
        _droppedBuf = bindings.allocBuffer(8) {
    _dataPtr = bindings.bufferDataPtr(_nativeBuf);
    _droppedPtr = bindings.bufferDataPtr(_droppedBuf).cast<ffi.Uint64>();
    _droppedPtr.value = 0;

    bindings.bufferFinalizer.attach(this, _nativeBuf, detach: this);
    bindings.bufferFinalizer.attach(this, _droppedBuf, detach: this);
    if (tapId > 0) {
      bindings.pullFinalizer.attach(
        this,
        ffi.Pointer.fromAddress(tapId),
        detach: this,
      );
    }

    _bytesView = _dataPtr.asTypedList(_byteLen);
    _f32View = _bytesView.buffer.asFloat32List(_bytesView.offsetInBytes, _byteLen ~/ 4);
    _i16View = _bytesView.buffer.asInt16List(_bytesView.offsetInBytes, _byteLen ~/ 2);
  }

  @override
  bool get isClosed => _closed;

  @override
  int get lastKnownDropped => _lastKnownDropped;

  @override
  int get droppedFrames {
    if (_closed) return _lastKnownDropped;
    final current = _bindings.getDropped(tapId);
    _lastKnownDropped = current;
    return current;
  }

  @override
  int pollFrames(int maxFrames) {
    if (_closed || maxFrames <= 0) return 0;
    final frames = _bindings.pollBytes(
      tapId,
      _dataPtr,
      _byteLen,
      maxFrames,
      _droppedPtr,
    );
    _lastKnownDropped = _droppedPtr.value;
    return frames;
  }

  @override
  Uint8List bytesSublistView(int byteLen) {
    final safeLen = byteLen.clamp(0, _bytesView.length);
    return Uint8List.sublistView(_bytesView, 0, safeLen);
  }

  @override
  Float32List float32SublistView(int sampleCount) {
    final safeLen = sampleCount.clamp(0, _f32View.length);
    return Float32List.sublistView(_f32View, 0, safeLen);
  }

  @override
  Int16List int16SublistView(int sampleCount) {
    final safeLen = sampleCount.clamp(0, _i16View.length);
    return Int16List.sublistView(_i16View, 0, safeLen);
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _bindings.pullFinalizer.detach(this);
    _bindings.closePull(tapId);
  }
}

PlatformTapBuffer createPlatformTapBuffer({
  required int tapId,
  required int bytesPerFrame,
  required int capacityFrames,
}) {
  return _IoPlatformTapBuffer(
    bindings: _resolveBindings(),
    tapId: tapId,
    bytesPerFrame: bytesPerFrame,
    capacityFrames: capacityFrames,
  );
}
