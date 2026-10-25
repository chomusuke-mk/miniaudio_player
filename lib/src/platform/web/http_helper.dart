import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

class RawHttpResponse {
  final int statusCode;
  final String reasonPhrase;
  final int contentLength;
  final Map<String, String> headers;
  final Stream<Uint8List> stream;
  final void Function() abort;

  const RawHttpResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.contentLength,
    required this.headers,
    required this.stream,
    required this.abort,
  });
}

Future<RawHttpResponse> sendHttpGetRequest(
  Uri uri, {
  Map<String, String>? headers,
}) async {
  final abortController = web.AbortController();
  final jsHeaders = web.Headers();
  if (headers != null) {
    headers.forEach((k, v) {
      // Skip restricted browser headers like User-Agent or Icy-MetaData if CORS blocks them,
      // though Range is standard CORS-safelisted/allowed.
      if (k.toLowerCase() != 'user-agent' && k.toLowerCase() != 'icy-metadata') {
        try {
          jsHeaders.append(k, v);
        } catch (_) {}
      }
    });
  }

  final init = web.RequestInit(
    method: 'GET',
    headers: jsHeaders,
    signal: abortController.signal,
  );

  final response = await web.window.fetch(uri.toString().toJS, init).toDart;
  final responseHeaders = <String, String>{};
  for (final name in [
    'content-length',
    'content-range',
    'accept-ranges',
    'content-type',
    'transfer-encoding',
    'retry-after',
    'icy-metaint',
    'icy-name',
    'icy-genre',
    'icy-br',
  ]) {
    final val = response.headers.get(name);
    if (val != null && val.isNotEmpty) {
      responseHeaders[name] = val;
    }
  }

  final contentLength =
      int.tryParse(responseHeaders['content-length'] ?? '') ?? -1;

  late StreamController<Uint8List> controller;
  bool cancelled = false;
  bool paused = false;
  Completer<void>? resumeCompleter;

  void abortRequest() {
    if (cancelled) return;
    cancelled = true;
    if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
      resumeCompleter!.complete();
    }
    try {
      abortController.abort();
    } catch (_) {}
  }

  Future<void> pumpBody() async {
    final body = response.body;
    if (body == null) {
      if (!controller.isClosed) await controller.close();
      return;
    }
    final reader =
        body.getReader() as web.ReadableStreamDefaultReader;
    try {
      while (!cancelled && !controller.isClosed) {
        if (paused) {
          resumeCompleter = Completer<void>();
          await resumeCompleter!.future;
          resumeCompleter = null;
          if (cancelled || controller.isClosed) break;
        }
        final result = await reader.read().toDart;
        if (result.done) {
          break;
        }
        final value = result.value;
        if (value != null && !controller.isClosed) {
          final uint8 = (value as JSUint8Array).toDart;
          controller.add(uint8);
        }
      }
      if (!controller.isClosed) {
        await controller.close();
      }
    } catch (e, st) {
      if (!cancelled && !controller.isClosed) {
        controller.addError(e, st);
        await controller.close();
      }
    } finally {
      try {
        reader.releaseLock();
      } catch (_) {}
    }
  }

  controller = StreamController<Uint8List>(
    onListen: () {
      pumpBody();
    },
    onPause: () {
      paused = true;
    },
    onResume: () {
      paused = false;
      if (resumeCompleter != null && !resumeCompleter!.isCompleted) {
        resumeCompleter!.complete();
      }
    },
    onCancel: () {
      abortRequest();
    },
  );

  return RawHttpResponse(
    statusCode: response.status,
    reasonPhrase: response.statusText,
    contentLength: contentLength,
    headers: responseHeaders,
    stream: controller.stream,
    abort: abortRequest,
  );
}
