/// Browser WebSocket audio stream provider using `dart:js_interop`.
///
/// @docImport '../api/miniaudio_player.dart';
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider_common.dart';

/// JavaScript `WebSocket` interop wrapper for browser streaming.
@JS('WebSocket')
extension type _JsWebSocket._(JSObject _) implements JSObject {
  /// Opens a browser WebSocket connection targeting [url].
  external factory _JsWebSocket(JSString url);

  /// Sets the binary frame payload type (configured to `'arraybuffer'`).
  external set binaryType(JSString value);

  /// Sets the connection-open event callback [fn].
  external set onopen(JSFunction? fn);

  /// Sets the incoming-message event callback [fn].
  external set onmessage(JSFunction? fn);

  /// Sets the transport-error event callback [fn].
  external set onerror(JSFunction? fn);

  /// Sets the connection-close event callback [fn].
  external set onclose(JSFunction? fn);

  /// Closes the WebSocket connection with an optional [code] and [reason].
  external void close([int? code, JSString? reason]);
}

/// JavaScript `MessageEvent` interop wrapper exposing incoming frame
/// [_JsMessageEvent.data].
extension type _JsMessageEvent._(JSObject _) implements JSObject {
  /// The raw JavaScript payload delivered by the WebSocket message event.
  external JSAny? get data;
}

/// Browser-backed [BaseWebSocketByteProvider] feeding frames into [fifo].
class _WebWebSocketByteProvider extends BaseWebSocketByteProvider {
  /// Underlying browser `WebSocket` instance.
  final _JsWebSocket _ws;

  /// Whether [close] has already disposed this provider.
  bool _disposed = false;

  /// Creates a Web WebSocket byte provider for [streamId] bound to [_ws].
  ///
  /// Installs `onmessage`, `onerror`, and `onclose` listeners that push
  /// incoming `ArrayBuffer` and non-empty text frames into [fifo].
  _WebWebSocketByteProvider(super.streamId, this._ws) {
    _ws.onmessage = ((_JsMessageEvent event) {
      if (_disposed) return;
      final data = event.data;
      if (data == null) return;
      if (data.isA<JSArrayBuffer>()) {
        final buf = (data as JSArrayBuffer).toDart;
        fifo.push(buf.asUint8List());
      } else if (data.isA<JSString>()) {
        final txt = (data as JSString).toDart;
        if (txt.isNotEmpty) {
          fifo.push(Uint8List.fromList(utf8.encode(txt)));
        }
      }
    }).toJS;

    _ws.onerror = ((JSAny? _) {
      if (_disposed) return;
      MapLogger.error(
        'Web WebSocket transport error on streamId=$streamId.',
      );
      fifo.markClosed(
        const MiniaudioPlayerException(
          'WebSocket audio stream encountered a transport error.',
          errorCode: MapResult.errorFileNotFound,
        ),
      );
    }).toJS;

    _ws.onclose = ((JSAny? _) {
      MapLogger.debug('Web WebSocket closed on streamId=$streamId.');
      fifo.markClosed();
    }).toJS;
  }

  /// Marks [fifo] closed, detaches JS handlers, and closes [_ws].
  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    MapLogger.debug('Disposing Web WebSocket provider streamId=$streamId.');
    fifo.markClosed();
    _ws.onmessage = null;
    _ws.onerror = null;
    _ws.onclose = null;
    _ws.onopen = null;
    try {
      _ws.close();
    } catch (e) {
      MapLogger.debug(
        'Ignoring error while closing Web WebSocket streamId=$streamId: $e',
      );
    }
  }
}

/// Connects to `ws://` or `wss://` [uri] in Web browsers via the browser
/// `WebSocket` API (`binaryType = 'arraybuffer'`).
///
/// Logs a warning if non-empty [headers] are passed because browser WebSockets
/// do not support arbitrary HTTP handshake headers. Rejects static analysis
/// calls when [isStaticAnalysis] is `true`, and enforces a 10-second connection
/// timeout.
Future<DartResolvedSourceResult> resolveWebSocketStream(
  String uri, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  if (isStaticAnalysis) {
    MapLogger.warn(
      'Rejected static analysis for live WebSocket stream "$uri" on Web.',
    );
    return DartResolvedError(
      MapResult.errorUnsupported,
      'Live WebSocket stream "$uri" cannot be pre-resolved statically for '
      'analyzeAudio(). Play it through a MiniaudioPlayer instance instead.',
    );
  }

  if (headers != null && headers.isNotEmpty) {
    MapLogger.warn(
      'Browser WebSocket API ignores custom HTTP headers for "$uri". '
      'Pass auth tokens via query parameters or subprotocol cookies on Web.',
    );
  }

  MapLogger.info('Opening Web WebSocket audio stream "$uri".');
  try {
    final ws = _JsWebSocket(uri.toJS);
    ws.binaryType = 'arraybuffer'.toJS;
    final openCompleter = Completer<void>();

    ws.onopen = ((JSAny? _) {
      if (!openCompleter.isCompleted) {
        openCompleter.complete();
      }
    }).toJS;

    ws.onerror = ((JSAny? _) {
      if (!openCompleter.isCompleted) {
        openCompleter.completeError(
          StateError('Browser WebSocket failed to connect to "$uri".'),
        );
      }
    }).toJS;

    ws.onclose = ((JSAny? _) {
      if (!openCompleter.isCompleted) {
        openCompleter.completeError(
          StateError('WebSocket connection closed before opening for "$uri".'),
        );
      }
    }).toJS;

    await openCompleter.future.timeout(const Duration(seconds: 10));
    final streamId = allocateManagedStreamId();
    final provider = _WebWebSocketByteProvider(streamId, ws);
    final hintExt = extractExtensionHintFromSource(uri);
    MapLogger.debug(
      'Connected Web WebSocket "$uri" -> streamId=$streamId '
      '(hintExt=$hintExt).',
    );
    return DartResolvedCustomStream(
      streamId: streamId,
      provider: provider,
      hintExt: hintExt,
    );
  } on TimeoutException catch (e) {
    MapLogger.error(
      'Timed out connecting to Web WebSocket "$uri": $e',
    );
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Timed out after 10s connecting to WebSocket audio stream "$uri".',
    );
  } catch (e) {
    MapLogger.error('WebSocket connection failed for "$uri": $e');
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'WebSocket connection failed for "$uri": $e',
    );
  }
}
