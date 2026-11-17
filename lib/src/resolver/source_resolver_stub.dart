import 'package:flutter/services.dart' show RootIsolateToken;

import 'source_resolver_common.dart';

/// Synchronously normalizes [rawUri] for the active compilation target.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  throw UnsupportedError('Platform source resolver stub is not usable directly.');
}

/// Registers an optional [RootIsolateToken] for background-isolate platform
/// channels and asset bundle resolution.
void registerSourceResolverIsolateToken(RootIsolateToken? token) {}

/// Synchronously resolves [normalizedSource] when possible (e.g. desktop
/// `flutter_assets` disk files), returning `null` if asynchronous resolution
/// is required.
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) => null;

/// Asynchronously resolves a source previously flagged with `resolveInDart`.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  return const DartResolvedError(
    -10,
    'Platform source resolver stub is unavailable.',
  );
}

/// Opens a writable detached POSIX file descriptor for an Android `content://` URI.
Future<int> openWritableAndroidContentFd(String uri) {
  throw UnsupportedError('Writable content:// descriptors are only supported on Android.');
}
