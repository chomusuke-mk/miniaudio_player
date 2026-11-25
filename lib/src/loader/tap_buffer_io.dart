import 'dart:ffi' as ffi;
import 'dart:typed_data';

import '../api/logger.dart';
import 'platform_loader_io.dart';
import 'tap_buffer_stub.dart';

export 'tap_buffer_stub.dart' show PlatformTapBuffer;

/// Native C signature for allocating a native tap byte buffer of [byteLen]
/// bytes.
typedef _AllocBufNative = ffi.Pointer<ffi.Void> Function(ffi.Size byteLen);

/// Dart FFI signature for allocating a native tap byte buffer of [byteLen]
/// bytes.
typedef _AllocBufDart = ffi.Pointer<ffi.Void> Function(int byteLen);

/// Native C signature for retrieving the raw data pointer of an allocated tap
/// buffer [buf].
typedef _BufPtrNative = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void> buf);

/// Dart FFI signature for retrieving the raw data pointer of an allocated tap
/// buffer [buf].
typedef _BufPtrDart = ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Void> buf);

/// Native C signature for resolving a `NativeFinalizer` callback pointer.
typedef _FinalizerCbNative = ffi.Pointer<ffi.NativeFinalizerFunction>
    Function();

/// Dart FFI signature for resolving a `NativeFinalizer` callback pointer.
typedef _FinalizerCbDart = ffi.Pointer<ffi.NativeFinalizerFunction> Function();

/// Native C signature for polling up to [maxFrames] from [tapId] into [dst]
/// of capacity [byteLen], writing dropped frames to [outDropped].
typedef _PollBytesNative = ffi.Uint32 Function(
  ffi.Uint32 tapId,
  ffi.Pointer<ffi.Uint8> dst,
  ffi.Size byteLen,
  ffi.Uint32 maxFrames,
  ffi.Pointer<ffi.Uint64> outDropped,
);

/// Dart FFI signature for polling up to [maxFrames] from [tapId] into [dst]
/// of capacity [byteLen], writing dropped frames to [outDropped].
typedef _PollBytesDart = int Function(
  int tapId,
  ffi.Pointer<ffi.Uint8> dst,
  int byteLen,
  int maxFrames,
  ffi.Pointer<ffi.Uint64> outDropped,
);

/// Native C signature for querying cumulative dropped frames for [tapId].
typedef _GetDroppedNative = ffi.Uint64 Function(ffi.Uint32 tapId);

/// Dart FFI signature for querying cumulative dropped frames for [tapId].
typedef _GetDroppedDart = int Function(int tapId);

/// Native C signature for closing the pull tap identified by [tapId].
typedef _ClosePullNative = ffi.Void Function(ffi.Uint32 tapId);

/// Dart FFI signature for closing the pull tap identified by [tapId].
typedef _ClosePullDart = void Function(int tapId);

/// Cached FFI function pointers and native finalizers for zero-copy pull taps.
final class _TapFfiBindings {
  /// Allocates a native buffer handle via `map_tap_alloc_buffer`.
  final _AllocBufDart allocBuffer;

  /// Resolves the raw byte pointer of a native buffer handle via
  /// `map_tap_buffer_data_ptr`.
  final _BufPtrDart bufferDataPtr;

  /// Polls PCM frames from the engine via `map_tap_poll_bytes`.
  final _PollBytesDart pollBytes;

  /// Reads cumulative dropped frames via `map_tap_get_dropped`.
  final _GetDroppedDart getDropped;

  /// Closes a pull tap handle via `map_tap_close_pull`.
  final _ClosePullDart closePull;

  /// Native finalizer that frees allocated tap buffers upon GC.
  final ffi.NativeFinalizer bufferFinalizer;

  /// Native finalizer that closes unclosed pull tap handles upon GC.
  final ffi.NativeFinalizer pullFinalizer;

  /// Resolves all tap FFI symbols from the dynamic library [lib].
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

/// Process-wide cached [_TapFfiBindings] instance.
_TapFfiBindings? _cachedBindings;

/// Resolves and caches [_TapFfiBindings] against [loadedNativeDynamicLibrary]
/// or the current process symbols.
_TapFfiBindings _resolveBindings() {
  final existing = _cachedBindings;
  if (existing != null) return existing;

  final lib = loadedNativeDynamicLibrary ?? ffi.DynamicLibrary.process();
  try {
    final resolved = _TapFfiBindings(lib);
    _cachedBindings = resolved;
    MapLogger.debug('Resolved native tap FFI bindings.');
    return resolved;
  } catch (e) {
    MapLogger.error('Failed to resolve native tap FFI bindings: $e');
    rethrow;
  }
}

/// Native FFI implementation of [PlatformTapBuffer] backed by a pinned native
/// allocation and typed-data views.
final class _IoPlatformTapBuffer implements PlatformTapBuffer, ffi.Finalizable {
  /// Resolved native FFI symbol bindings.
  final _TapFfiBindings _bindings;

  /// Native engine identifier assigned to this pull tap.
  @override
  final int tapId;

  /// Total capacity of [_bytesView] in bytes.
  final int _byteLen;

  /// Opaque native handle owning the reusable PCM frame buffer.
  final ffi.Pointer<ffi.Void> _nativeBuf;

  /// Direct byte pointer into [_nativeBuf].
  late final ffi.Pointer<ffi.Uint8> _dataPtr;

  /// Opaque native handle owning the 8-byte out-parameter for dropped frames.
  final ffi.Pointer<ffi.Void> _droppedBuf;

  /// Direct `uint64` pointer into [_droppedBuf].
  late final ffi.Pointer<ffi.Uint64> _droppedPtr;

  /// Byte view backed directly by [_dataPtr].
  late final Uint8List _bytesView;

  /// Float32 view backed directly by [_dataPtr].
  late final Float32List _f32View;

  /// Signed 16-bit PCM view backed directly by [_dataPtr].
  late final Int16List _i16View;

  /// Whether [close] has already been called.
  bool _closed = false;

  /// Most recently observed dropped-frame total.
  int _lastKnownDropped = 0;

  /// Allocates a reusable native tap buffer bound to [bindings] and [tapId]
  /// for [capacityFrames] frames of [bytesPerFrame] bytes each.
  _IoPlatformTapBuffer({
    required _TapFfiBindings bindings,
    required this.tapId,
    required int bytesPerFrame,
    required int capacityFrames,
  })  : _bindings = bindings,
        _byteLen = (capacityFrames * bytesPerFrame).clamp(1, 1 << 30),
        _nativeBuf = bindings
            .allocBuffer((capacityFrames * bytesPerFrame).clamp(1, 1 << 30)),
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
    _f32View = _bytesView.buffer
        .asFloat32List(_bytesView.offsetInBytes, _byteLen ~/ 4);
    _i16View =
        _bytesView.buffer.asInt16List(_bytesView.offsetInBytes, _byteLen ~/ 2);
    MapLogger.debug(
      'Created IO PlatformTapBuffer(tapId=$tapId, byteLen=$_byteLen).',
    );
  }

  /// Whether this tap buffer has been closed.
  @override
  bool get isClosed => _closed;

  /// Returns the cached cumulative dropped-frame count from the last query or
  /// poll.
  @override
  int get lastKnownDropped => _lastKnownDropped;

  /// Queries the native engine for cumulative dropped frames on [tapId].
  @override
  int get droppedFrames {
    if (_closed) return _lastKnownDropped;
    final current = _bindings.getDropped(tapId);
    _lastKnownDropped = current;
    return current;
  }

  /// Polls up to [maxFrames] PCM frames from the native engine into [_dataPtr]
  /// and returns the number of frames copied.
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

  /// Returns a [Uint8List] sublist view covering the first [byteLen] bytes of
  /// [_bytesView].
  @override
  Uint8List bytesSublistView(int byteLen) {
    final safeLen = byteLen.clamp(0, _bytesView.length);
    return Uint8List.sublistView(_bytesView, 0, safeLen);
  }

  /// Returns a [Float32List] sublist view covering the first [sampleCount]
  /// samples of [_f32View].
  @override
  Float32List float32SublistView(int sampleCount) {
    final safeLen = sampleCount.clamp(0, _f32View.length);
    return Float32List.sublistView(_f32View, 0, safeLen);
  }

  /// Returns an [Int16List] sublist view covering the first [sampleCount]
  /// samples of [_i16View].
  @override
  Int16List int16SublistView(int sampleCount) {
    final safeLen = sampleCount.clamp(0, _i16View.length);
    return Int16List.sublistView(_i16View, 0, safeLen);
  }

  /// Detaches the pull finalizer and closes the native pull tap handle [tapId].
  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _bindings.pullFinalizer.detach(this);
    _bindings.closePull(tapId);
    MapLogger.debug('Closed IO PlatformTapBuffer(tapId=$tapId).');
  }
}

/// Creates an FFI-backed [PlatformTapBuffer] bound to [tapId] with backing
/// storage for [capacityFrames] frames of [bytesPerFrame] bytes each.
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
