import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider_common.dart';

@JS('WebSocket')
extension type _JsWebSocket._(JSObject _) implements JSObject {
  external factory _JsWebSocket(JSString url);
  external set binaryType(JSString value);
  external set onopen(JSFunction? fn);
  external set onmessage(JSFunction? fn);
  external set onerror(JSFunction? fn);
  external set onclose(JSFunction? fn);
  external void close([int? code, JSString? reason]);
}

extension type _JsMessageEvent._(JSObject _) implements JSObject {
  external JSAny? get data;
}

class _WebWebSocketByteProvider extends BaseWebSocketByteProvider {
  final _JsWebSocket _ws;
  bool _disposed = false;

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
      fifo.markClosed(
        const MiniaudioPlayerException(
          'WebSocket audio stream encountered a transport error.',
          errorCode: MapResult.errorFileNotFound,
        ),
      );
    }).toJS;

    _ws.onclose = ((JSAny? _) {
      fifo.markClosed();
    }).toJS;
  }

  @override
  Future<void> close() async {
    if (_disposed) return;
    _disposed = true;
    fifo.markClosed();
    _ws.onmessage = null;
    _ws.onerror = null;
    _ws.onclose = null;
    _ws.onopen = null;
    try {
      _ws.close();
    } catch (_) {}
  }
}

/// Connects to `ws://` / `wss://` in Web browsers via browser [WebSocket]
/// (`binaryType = 'arraybuffer'`).
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

  if (headers != null && headers.isNotEmpty) {
    MapLogger.warn(
      'Browser WebSocket API ignores custom HTTP headers for "$uri". '
      'Pass auth tokens via query parameters or subprotocol cookies on Web.',
    );
  }

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
  } catch (e) {
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'WebSocket connection failed for "$uri": $e',
    );
  }
}
