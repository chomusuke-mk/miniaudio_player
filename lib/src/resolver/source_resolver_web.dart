/// Web platform source normalization and deferred URI resolver.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/services.dart' show RootIsolateToken;

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider.dart';

/// Registers [token] for background-isolate messaging.
///
/// Performs no operation on Web because WebAssembly targets do not run Dart
/// background isolates with Flutter platform channels.
void registerSourceResolverIsolateToken(RootIsolateToken? token) {
  MapLogger.verbose(
    'registerSourceResolverIsolateToken skipped on Web '
    '(hasToken=${token != null}).',
  );
}

/// Synchronously normalizes [rawUri] for Flutter Web targets.
///
/// Delegates to [normalizeAudioSourceUri] with Web flags enabled and the
/// active [kDebugMode] flag.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  return normalizeAudioSourceUri(
    rawUri,
    isWeb: true,
    isWindows: false,
    isAndroid: false,
    isDebug: kDebugMode,
  );
}

/// Attempts synchronous local resolution for [normalizedSource] on Web.
///
/// Always returns `null` because Web `asset://` URIs already normalize
/// synchronously to HTTP URLs via [normalizePlatformAudioSourceUri].
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) => null;

/// Asynchronously resolves [normalizedSource] on Flutter Web with optional
/// HTTP [headers] and [isStaticAnalysis] validation.
///
/// Supports `ws://` and `wss://` live streams via [resolveWebSocketStream], as
/// well as direct `asset://` URIs when explicitly requested.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  final scheme = extractUriScheme(normalizedSource);
  MapLogger.debug(
    'Resolving Web deferred source "$normalizedSource" (scheme=$scheme, '
    'isStaticAnalysis=$isStaticAnalysis).',
  );
  switch (scheme) {
    case 'asset':
      final assetKey = extractRelativeAssetKey(normalizedSource);
      if (assetKey.isEmpty) {
        MapLogger.warn(
          'Rejected empty Web asset key in "$normalizedSource".',
        );
        return DartResolvedError(
          MapResult.errorInvalidArgs,
          'Invalid empty asset key in "$normalizedSource".',
        );
      }
      final url = buildFlutterWebAssetUrl(assetKey, doubleEncode: true);
      MapLogger.debug('Resolved Web asset "$normalizedSource" -> "$url".');
      return DartResolvedUrl(url);
    case 'ws':
    case 'wss':
      return resolveWebSocketStream(
        normalizedSource,
        headers: headers,
        isStaticAnalysis: isStaticAnalysis,
      );
    default:
      MapLogger.warn(
        'Unsupported deferred source URI "$normalizedSource" on Web.',
      );
      return DartResolvedError(
        MapResult.errorUnsupported,
        'Unsupported deferred source URI "$normalizedSource" on Web.',
      );
  }
}

/// Opens a writable Android `content://` descriptor for [uri].
///
/// Always throws a [MiniaudioPlayerException] with [MapResult.errorUnsupported]
/// because Android Storage Access Framework descriptors are unavailable on Web.
Future<int> openWritableAndroidContentFd(String uri) async {
  MapLogger.warn(
    'Rejected writable Android content:// URI "$uri" on Web.',
  );
  throw MiniaudioPlayerException(
    'Android content:// recording URI "$uri" is not supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}
