/// Platform-conditional exports for loading the native or WebAssembly library.
library;

export 'platform_loader_io.dart'
    if (dart.library.js_interop) 'platform_loader_web.dart';
