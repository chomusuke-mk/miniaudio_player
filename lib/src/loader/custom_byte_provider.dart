import 'dart:async';
import 'dart:typed_data';

import '../platform/platform_backend.dart';
import '../rust/api/types.dart';

/// Contract for asynchronous custom byte streams in Dart (DRM, encrypted streams, tokenized storage).
abstract class CustomByteProvider {
  /// Stream identifier matching Rust's stream_id.
  int get streamId;

  /// Total size of the stream in bytes, or `null` for unknown / unbounded streams.
  int? get totalBytes;

  /// Whether random-access seeking is supported.
  bool get isSeekable;

  /// Reads initial probe bytes (e.g. headers, format detection bytes).
  Future<Uint8List> readInitialBytes();

  /// Asynchronously fetches [length] bytes starting from [offset].
  Future<Uint8List> readBytes(int offset, int length);

  /// Closes the provider and releases any underlying connections or resources.
  Future<void> close();
}

/// Bridges a Dart [CustomByteProvider] to the Rust `CustomDartByteSource` over FRB.
class DartByteProviderBridge {
  final PlayerBackend _backend;
  final CustomByteProvider _provider;
  StreamSubscription<RustDartReadRequest>? _subscription;

  DartByteProviderBridge(this._backend, this._provider);

  /// Starts the custom byte bridge by reading initial bytes and opening the stream in Rust.
  Future<void> start() async {
    _subscription = _backend.onDartReadRequest.listen(_handleReadRequest);

    final initial = await _provider.readInitialBytes();
    await _backend.openCustomStream(
      streamId: _provider.streamId,
      totalSize: _provider.totalBytes,
      isSeekable: _provider.isSeekable,
      initialBytes: initial,
    );
  }

  Future<void> _handleReadRequest(RustDartReadRequest req) async {
    if (req.streamId != _provider.streamId) return;
    try {
      final chunk = await _provider.readBytes(
        req.offset.toInt(),
        req.length,
      );
      final isEof = chunk.length < req.length;
      _backend.supplyCustomBytes(
        streamId: _provider.streamId,
        requestId: req.requestId.toInt(),
        data: chunk,
        isEof: isEof,
      );
    } catch (e) {
      _backend.notifyCustomError(
        streamId: _provider.streamId,
        requestId: req.requestId.toInt(),
        errorMessage: e.toString(),
      );
    }
  }

  /// Cancels active subscriptions and closes the underlying provider.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _provider.close();
  }
}
