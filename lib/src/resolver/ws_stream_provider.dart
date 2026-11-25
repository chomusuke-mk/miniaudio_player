/// Cross-platform WebSocket audio stream provider exports.
///
/// Selects the native `dart:io` provider, the browser `dart:js_interop`
/// provider, or the fallback stub implementation based on the active target.
library;

export 'ws_stream_provider_stub.dart'
    if (dart.library.io) 'ws_stream_provider_io.dart'
    if (dart.library.js_interop) 'ws_stream_provider_web.dart';
