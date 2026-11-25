/// Fallback stub implementation for platform source resolution.
library;

import 'package:flutter/services.dart' show RootIsolateToken;

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';

/// Synchronously normalizes [rawUri] for the active compilation target.
///
/// Always throws an [UnsupportedError] because this stub is only selected on
/// targets that lack both `dart:io` and `dart:js_interop`.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  MapLogger.error(
    'normalizePlatformAudioSourceUri called on unsupported stub target for '
    '"$rawUri".',
  );
  throw UnsupportedError(
      'Platform source resolver stub is not usable directly.');
}

/// Registers an optional [token] for background-isolate platform channels and
/// asset bundle resolution.
///
/// Performs no operation on the unsupported stub target.
void registerSourceResolverIsolateToken(RootIsolateToken? token) {
  MapLogger.debug(
    'registerSourceResolverIsolateToken ignored on stub target '
    '(hasToken=${token != null}).',
  );
}

/// Synchronously resolves [normalizedSource] when local disk access is
/// available.
///
/// Always returns `null` on the unsupported stub target.
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) {
  MapLogger.verbose(
    'tryResolveSourceSync returning null on stub target for '
    '"$normalizedSource".',
  );
  return null;
}

/// Asynchronously resolves [normalizedSource] with optional HTTP [headers] and
/// [isStaticAnalysis] mode flag.
///
/// Always returns a [DartResolvedError] with [MapResult.errorUnsupported] on
/// the unsupported stub target.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  MapLogger.warn(
    'resolveSourceAsync called on unsupported stub target for '
    '"$normalizedSource" (headers=${headers?.length ?? 0}, '
    'isStaticAnalysis=$isStaticAnalysis).',
  );
  return const DartResolvedError(
    MapResult.errorUnsupported,
    'Platform source resolver stub is unavailable.',
  );
}

/// Opens a writable detached POSIX file descriptor for an Android `content://`
/// [uri].
///
/// Always throws an [UnsupportedError] on the unsupported stub target.
Future<int> openWritableAndroidContentFd(String uri) {
  MapLogger.warn(
    'openWritableAndroidContentFd called on unsupported stub target for "$uri".',
  );
  throw UnsupportedError(
    'Writable content:// descriptors are only supported on Android.',
  );
}
