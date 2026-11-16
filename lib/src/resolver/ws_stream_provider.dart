export 'ws_stream_provider_stub.dart'
    if (dart.library.io) 'ws_stream_provider_io.dart'
    if (dart.library.js_interop) 'ws_stream_provider_web.dart';
