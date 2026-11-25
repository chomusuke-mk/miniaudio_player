/// Fallback stub implementation for WebSocket audio stream resolution.
library;

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';

/// Connects to the WebSocket audio stream at [uri] using optional [headers]
/// and [isStaticAnalysis] validation.
///
/// Always returns a [DartResolvedError] with [MapResult.errorUnsupported] on
/// targets that lack both `dart:io` and `dart:js_interop`.
Future<DartResolvedSourceResult> resolveWebSocketStream(
  String uri, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  MapLogger.warn(
    'WebSocket audio streaming is unavailable on stub target for "$uri" '
    '(headers=${headers?.length ?? 0}, isStaticAnalysis=$isStaticAnalysis).',
  );
  return const DartResolvedError(
    MapResult.errorUnsupported,
    'WebSocket audio streaming is unavailable on this platform target.',
  );
}
