/// Platform-conditional exports for zero-allocation audio pull tap buffers.
library;

export 'tap_buffer_stub.dart'
    if (dart.library.ffi) 'tap_buffer_io.dart'
    if (dart.library.js_interop) 'tap_buffer_web.dart';
