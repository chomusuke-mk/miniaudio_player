export 'source_resolver_common.dart';
export 'source_resolver_stub.dart'
    if (dart.library.io) 'source_resolver_io.dart'
    if (dart.library.js_interop) 'source_resolver_web.dart';
