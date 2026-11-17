import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show RootIsolateToken;

import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider.dart';

/// Registers [token] (no-op on Web because WebAssembly does not run Dart
/// background isolates).
void registerSourceResolverIsolateToken(RootIsolateToken? token) {}

/// Synchronously normalizes [rawUri] for Flutter Web.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  return normalizeAudioSourceUri(
    rawUri,
    isWeb: true,
    isWindows: false,
    isAndroid: false,
    isDebug: kDebugMode,
  );
}

/// Web `asset://` URIs already normalize synchronously to HTTP URLs.
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) => null;

/// Asynchronously resolves `ws://`/`wss://` (and direct `asset://` if explicitly
/// requested) on Flutter Web.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  final scheme = extractUriScheme(normalizedSource);
  switch (scheme) {
    case 'asset':
      final assetKey = extractRelativeAssetKey(normalizedSource);
      if (assetKey.isEmpty) {
        return DartResolvedError(
          MapResult.errorInvalidArgs,
          'Invalid empty asset key in "$normalizedSource".',
        );
      }
      return DartResolvedUrl(
        buildFlutterWebAssetUrl(assetKey, doubleEncode: true),
      );
    case 'ws':
    case 'wss':
      return resolveWebSocketStream(
        normalizedSource,
        headers: headers,
        isStaticAnalysis: isStaticAnalysis,
      );
    default:
      return DartResolvedError(
        MapResult.errorUnsupported,
        'Unsupported deferred source URI "$normalizedSource" on Web.',
      );
  }
}

/// Throws [MiniaudioPlayerException] with [MapResult.errorUnsupported] on Web.
Future<int> openWritableAndroidContentFd(String uri) async {
  throw MiniaudioPlayerException(
    'Android content:// recording URI "$uri" is not supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}
