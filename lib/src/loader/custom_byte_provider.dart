import 'dart:async';
import 'dart:typed_data';

import '../api/logger.dart';
import '../rust/api/player.dart' as rust;
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
  final rust.RustMiniaudioPlayer _rust;
  final CustomByteProvider _provider;
  final Stream<RustDartReadRequest> _requestStream;
  StreamSubscription<RustDartReadRequest>? _subscription;

  DartByteProviderBridge({
    required rust.RustMiniaudioPlayer rust,
    required CustomByteProvider provider,
    required Stream<RustDartReadRequest> requestStream,
  })  : _rust = rust,
        _provider = provider,
        _requestStream = requestStream;

  /// Starts the custom byte bridge by listening to read requests.
  Future<void> start() async {
    MapLogger.info(
      'DartByteProviderBridge starting (streamId: ${_provider.streamId}, '
      'totalBytes: ${_provider.totalBytes}, seekable: ${_provider.isSeekable})',
    );
    _subscription = _requestStream.listen(_handleReadRequest);
  }

  Future<void> _handleReadRequest(RustDartReadRequest req) async {
    if (req.streamId != _provider.streamId) return;
    MapLogger.verbose(
      'CustomByteProvider read request -> offset: ${req.offset}, '
      'length: ${req.length}, requestId: ${req.requestId}',
    );
    try {
      final chunk = await _provider.readBytes(
        req.offset.toInt(),
        req.length,
      );
      final isEof = chunk.length < req.length;
      _rust.respondDartReadRequest(
        requestId: req.requestId,
        bytes: chunk,
        isEof: isEof,
      );
    } catch (e) {
      MapLogger.error(
        'CustomByteProvider read error (requestId: ${req.requestId}): $e',
      );
    }
  }

  /// Cancels active subscriptions and closes the underlying provider.
  void dispose() {
    MapLogger.debug(
      'DartByteProviderBridge disposed for streamId: ${_provider.streamId}',
    );
    _subscription?.cancel();
    _subscription = null;
    _provider.close();
  }
}
