/// Cross-platform audio source normalization and resolution exports.
///
/// Selects the native `dart:io` resolver, the Web `dart:js_interop` resolver,
/// or the fallback stub implementation based on the active compilation target.
library;

export 'source_resolver_common.dart';
export 'source_resolver_stub.dart'
    if (dart.library.io) 'source_resolver_io.dart'
    if (dart.library.js_interop) 'source_resolver_web.dart';
