import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider_common.dart';

class _IoWebSocketByteProvider extends BaseWebSocketByteProvider {
  final WebSocket _socket;
  late final StreamSubscription<dynamic> _subscription;
  bool _disposed = false;

  _IoWebSocketByteProvider(super.streamId, this._socket) {
    _subscription = _socket.listen(
      (dynamic event) {
        if (_disposed) return;
        if (event is Uint8List) {
          fifo.push(event);
        } else if (event is List<int>) {
          fifo.push(Uint8List.fromList(event));
        } else if (event is String && event.isNotEmpty) {
          fifo.push(Uint8List.fromList(utf8.encode(event)));
        }
      },
      onError: (Object err) {
        fifo.markClosed(err);
      },
      onDone: () {
        fifo.markClosed();
      },
      cancelOnError: true,
    );
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    fifo.markClosed();
    try {
      await _subscription.cancel();
    } catch (_) {}
    try {
      await _socket.close();
    } catch (_) {}
  }
}

/// Connects to `ws://` / `wss://` on Native targets using `dart:io` [WebSocket]
/// with custom [headers] support and returns a sequential FIFO stream provider.
Future<DartResolvedSourceResult> resolveWebSocketStream(
  String uri, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  if (isStaticAnalysis) {
    return DartResolvedError(
      MapResult.errorUnsupported,
      'Live WebSocket stream "$uri" cannot be pre-resolved statically for analyzeAudio(). '
      'Play it through a MiniaudioPlayer instance instead.',
    );
  }

  try {
    final socket = await WebSocket.connect(uri, headers: headers)
        .timeout(const Duration(seconds: 10));
    final streamId = allocateManagedStreamId();
    final provider = _IoWebSocketByteProvider(streamId, socket);
    return DartResolvedCustomStream(
      streamId: streamId,
      provider: provider,
      hintExt: extractExtensionHintFromSource(uri),
    );
  } on TimeoutException {
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Timed out after 10s connecting to WebSocket audio stream "$uri".',
    );
  } on WebSocketException catch (e) {
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'WebSocket handshake failed for "$uri": ${e.message}',
    );
  } on SocketException catch (e) {
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Failed to connect to WebSocket "$uri": ${e.message}',
    );
  } catch (e) {
    return DartResolvedError(
      MapResult.errorGeneric,
      'Unexpected error opening WebSocket "$uri": $e',
    );
  }
}
