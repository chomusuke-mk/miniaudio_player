import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

const String defaultHttpUserAgent =
    'miniaudio_player/1.0 (+https://pub.dev/packages/miniaudio_player; Dart audio engine)';

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
  final client = HttpClient()
    ..userAgent = defaultHttpUserAgent
    ..autoUncompress = false;

  try {
    final req = await client.getUrl(uri);
    if (headers != null) {
      headers.forEach((k, v) => req.headers.set(k, v));
    }
    if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
      req.headers.set(HttpHeaders.userAgentHeader, defaultHttpUserAgent);
    }
    final res = await req.close();
    final responseHeaders = <String, String>{};
    res.headers.forEach((name, values) {
      if (values.isNotEmpty) {
        responseHeaders[name.toLowerCase()] = values.join(', ');
      }
    });

    late StreamController<Uint8List> controller;
    StreamSubscription<List<int>>? sub;

    void closeClient() {
      sub?.cancel();
      sub = null;
      try {
        client.close(force: true);
      } catch (_) {}
    }

    controller = StreamController<Uint8List>(
      sync: true,
      onListen: () {
        sub = res.listen(
          (chunk) {
            if (!controller.isClosed) {
              controller.add(
                chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
              );
            }
          },
          onError: (Object err, StackTrace st) {
            if (!controller.isClosed) {
              controller.addError(err, st);
              controller.close();
            }
            closeClient();
          },
          onDone: () {
            if (!controller.isClosed) {
              controller.close();
            }
            closeClient();
          },
          cancelOnError: true,
        );
      },
      onPause: () => sub?.pause(),
      onResume: () => sub?.resume(),
      onCancel: () {
        closeClient();
      },
    );

    return RawHttpResponse(
      statusCode: res.statusCode,
      reasonPhrase: res.reasonPhrase,
      contentLength: res.contentLength,
      headers: responseHeaders,
      stream: controller.stream,
      abort: closeClient,
    );
  } catch (e) {
    try {
      client.close(force: true);
    } catch (_) {}
    rethrow;
  }
}

/// Decompresses [bytes] if a gzip header (0x1F 0x8B) is present.
Uint8List decompressIfGzip(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B) {
    try {
      return Uint8List.fromList(gzip.decode(bytes));
    } catch (_) {}
  }
  return bytes;
}
