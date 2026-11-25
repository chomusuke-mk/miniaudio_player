/// Native `dart:io` WebSocket audio stream provider.
///
/// @docImport '../api/miniaudio_player.dart';
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider_common.dart';

/// Native `dart:io` [BaseWebSocketByteProvider] backed by a [WebSocket].
class _IoWebSocketByteProvider extends BaseWebSocketByteProvider {
  /// Active `dart:io` WebSocket connection.
  final WebSocket _socket;

  /// Subscription listening for incoming binary and text WebSocket frames.
  late final StreamSubscription<dynamic> _subscription;

  /// Whether [close] has already disposed this provider.
  bool _disposed = false;

  /// Creates an IO WebSocket byte provider for [streamId] bound to [_socket].
  ///
  /// Subscribes to [_socket] events and forwards binary or UTF-8 frames into
  /// [fifo] until the socket closes or emits an error.
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
        MapLogger.error('IO WebSocket error on streamId=$streamId: $err');
        fifo.markClosed(err);
      },
      onDone: () {
        MapLogger.debug(
            'IO WebSocket stream completed for streamId=$streamId.');
        fifo.markClosed();
      },
      cancelOnError: true,
    );
  }

  /// Marks [fifo] closed, cancels [_subscription], and closes [_socket].
  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    MapLogger.debug('Disposing IO WebSocket provider streamId=$streamId.');
    fifo.markClosed();
    try {
      await _subscription.cancel();
    } catch (e) {
      MapLogger.debug(
        'Ignoring error cancelling IO WebSocket subscription '
        '(streamId=$streamId): $e',
      );
    }
    try {
      await _socket.close();
    } catch (e) {
      MapLogger.debug(
        'Ignoring error closing IO WebSocket (streamId=$streamId): $e',
      );
    }
  }
}

/// Connects to `ws://` or `wss://` [uri] on native targets using `dart:io`
/// [WebSocket] with optional handshake [headers].
///
/// Rejects static analysis calls when [isStaticAnalysis] is `true`, enforces a
/// 10-second connection timeout, and wraps the connected socket in a
/// [DartResolvedCustomStream] backed by a sequential FIFO provider.
Future<DartResolvedSourceResult> resolveWebSocketStream(
  String uri, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  if (isStaticAnalysis) {
    MapLogger.warn(
      'Rejected static analysis for live WebSocket stream "$uri".',
    );
    return DartResolvedError(
      MapResult.errorUnsupported,
      'Live WebSocket stream "$uri" cannot be pre-resolved statically for '
      'analyzeAudio(). Play it through a MiniaudioPlayer instance instead.',
    );
  }

  MapLogger.info(
    'Connecting IO WebSocket audio stream "$uri" '
    '(customHeaders=${headers?.length ?? 0}).',
  );
  try {
    final socket = await WebSocket.connect(uri, headers: headers)
        .timeout(const Duration(seconds: 10));
    final streamId = allocateManagedStreamId();
    final provider = _IoWebSocketByteProvider(streamId, socket);
    final hintExt = extractExtensionHintFromSource(uri);
    MapLogger.debug(
      'Connected IO WebSocket "$uri" -> streamId=$streamId (hintExt=$hintExt).',
    );
    return DartResolvedCustomStream(
      streamId: streamId,
      provider: provider,
      hintExt: hintExt,
    );
  } on TimeoutException catch (e) {
    MapLogger.error('Timed out connecting IO WebSocket "$uri": $e');
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Timed out after 10s connecting to WebSocket audio stream "$uri".',
    );
  } on WebSocketException catch (e) {
    MapLogger.error('WebSocket handshake failed for "$uri": ${e.message}');
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'WebSocket handshake failed for "$uri": ${e.message}',
    );
  } on SocketException catch (e) {
    MapLogger.error('Socket failure connecting WebSocket "$uri": ${e.message}');
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Failed to connect to WebSocket "$uri": ${e.message}',
    );
  } catch (e) {
    MapLogger.error('Unexpected error opening WebSocket "$uri": $e');
    return DartResolvedError(
      MapResult.errorGeneric,
      'Unexpected error opening WebSocket "$uri": $e',
    );
  }
}
