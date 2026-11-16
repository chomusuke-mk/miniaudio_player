import '../api/player_exception.dart';
import 'source_resolver_common.dart';

/// Connects a WebSocket stream and wraps it into a [DartResolvedCustomStream].
Future<DartResolvedSourceResult> resolveWebSocketStream(
  String uri, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  return const DartResolvedError(
    MapResult.errorUnsupported,
    'WebSocket audio streaming is unavailable on this platform target.',
  );
}
