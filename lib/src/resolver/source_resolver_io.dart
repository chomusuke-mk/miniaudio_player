import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError, visibleForTesting;
import 'package:flutter/services.dart'
    show
        BackgroundIsolateBinaryMessenger,
        MethodChannel,
        MissingPluginException,
        PlatformException,
        RootIsolateToken,
        ServicesBinding,
        rootBundle;
import 'package:path/path.dart' as p;

import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider.dart';

const MethodChannel _androidResolverChannel = MethodChannel(
  'dev.chomusuke.miniaudio_player/source_resolver',
);

bool _detectDebugMode() {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}

/// Registers [token] so background isolates can invoke `'flutter/assets'` and
/// Android `'dev.chomusuke.miniaudio_player/source_resolver'`.
void registerSourceResolverIsolateToken(RootIsolateToken? token) {
  if (token == null) return;
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
}

/// Synchronously normalizes [rawUri] for Native (Linux, Windows, macOS,
/// Android, iOS) targets.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  return normalizeAudioSourceUri(
    rawUri,
    isWeb: false,
    isWindows: Platform.isWindows,
    isAndroid: Platform.isAndroid,
    isDebug: _detectDebugMode(),
  );
}

/// Attempts fast, non-allocating disk resolution for desktop `flutter_assets`
/// files (`<exe>/data/flutter_assets` on Linux/Windows,
/// `<exe>/../Frameworks/App.framework/Resources/flutter_assets` on macOS).
String? _tryFindDesktopFlutterAssetFile(String assetKey) {
  if (!(Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
    return null;
  }

  final rawSegments = assetKey
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .toList(growable: false);
  if (rawSegments.isEmpty || rawSegments.any((s) => s == '..')) {
    return null;
  }

  final exeDir = p.dirname(Platform.resolvedExecutable);
  final assetsDir = Platform.isMacOS
      ? p.normalize(
          p.join(
            exeDir,
            '..',
            'Frameworks',
            'App.framework',
            'Resources',
            'flutter_assets',
          ),
        )
      : p.join(exeDir, 'data', 'flutter_assets');

  if (!Directory(assetsDir).existsSync()) {
    return null;
  }

  // Flutter Desktop writes asset paths using URI segment encoding
  // (e.g. '#foo.opus' -> '%23foo.opus'). Try encoded path first, then raw.
  final encodedSegments = Uri(pathSegments: rawSegments)
      .path
      .split('/')
      .where((s) => s.isNotEmpty)
      .toList(growable: false);
  final candidates = <String>[
    p.joinAll(<String>[assetsDir, ...encodedSegments]),
    p.joinAll(<String>[assetsDir, ...rawSegments]),
  ];

  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}

/// Attempts synchronous resolution for local disk assets (desktop
/// `flutter_assets`). Returns `null` when asynchronous platform channels or
/// bundle loaders are needed.
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) {
  final scheme = extractUriScheme(normalizedSource);
  if (scheme == 'asset') {
    final key = extractRelativeAssetKey(normalizedSource);
    final diskPath = _tryFindDesktopFlutterAssetFile(key);
    if (diskPath != null) {
      return DartResolvedPath(diskPath);
    }
  }
  return null;
}

/// Asynchronously resolves `asset://`, `content://`, `android.resource://`,
/// and `ws://`/`wss://` on Native targets.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  final scheme = extractUriScheme(normalizedSource);
  switch (scheme) {
    case 'asset':
      return _resolveAssetNative(normalizedSource);
    case 'content':
    case 'android.resource':
      if (!Platform.isAndroid) {
        return DartResolvedError(
          MapResult.errorUnsupported,
          'URI scheme "$scheme://" ("$normalizedSource") is only supported on Android.',
        );
      }
      return _resolveAndroidContentOrResource(normalizedSource, scheme!);
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
        'Unsupported deferred source URI "$normalizedSource".',
      );
  }
}

bool _hasActiveServicesBinding() {
  try {
    ServicesBinding.instance;
    return true;
  } on FlutterError {
    return false;
  } catch (_) {
    return false;
  }
}

Future<DartResolvedSourceResult> _resolveAssetNative(
  String normalizedSource,
) async {
  final assetKey = extractRelativeAssetKey(normalizedSource);
  if (assetKey.isEmpty || assetKey.split('/').contains('..')) {
    return DartResolvedError(
      MapResult.errorInvalidArgs,
      'Invalid asset key in "$normalizedSource".',
    );
  }

  final diskPath = _tryFindDesktopFlutterAssetFile(assetKey);
  if (diskPath != null) {
    return DartResolvedPath(diskPath);
  }

  final extHint = extractExtensionHintFromSource(assetKey);
  try {
    if (_hasActiveServicesBinding()) {
      final data = await rootBundle.load(assetKey);
      return DartResolvedBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        hintExt: extHint,
      );
    }

    // Background isolate path: `rootBundle` ignores BackgroundIsolateBinaryMessenger,
    // so send directly to the engine's `'flutter/assets'` channel.
    final encodedKey = Uri(path: Uri.encodeFull(assetKey)).path;
    final keyBytes = Uint8List.fromList(utf8.encode(encodedKey));
    final data = await BackgroundIsolateBinaryMessenger.instance.send(
      'flutter/assets',
      keyBytes.buffer.asByteData(),
    );
    if (data == null) {
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Flutter asset not found: "$assetKey". Ensure it is declared under flutter.assets in pubspec.yaml.',
      );
    }
    return DartResolvedBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      hintExt: extHint,
    );
  } on StateError catch (e) {
    return DartResolvedError(
      MapResult.errorInvalidState,
      'Cannot load Flutter asset "$normalizedSource" in a background isolate '
      'because RootIsolateToken has not been initialized. Obtain '
      'RootIsolateToken.instance on the main isolate and pass it to '
      'MiniaudioPlayer.ensureInitialized(rootIsolateToken: token). ($e)',
    );
  } on FlutterError catch (e) {
    final msg = e.message;
    if (msg.contains('Unable to load asset')) {
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Flutter asset not found: "$assetKey". Ensure it is declared under '
        'flutter.assets in pubspec.yaml. ($msg)',
      );
    }
    if (msg.contains('ServicesBinding') || msg.contains('binding')) {
      return DartResolvedError(
        MapResult.errorInvalidState,
        'Cannot load Flutter asset "$normalizedSource" before Flutter bindings '
        'or RootIsolateToken are initialized. Call '
        'WidgetsFlutterBinding.ensureInitialized() on the main isolate or pass '
        'RootIsolateToken.instance to MiniaudioPlayer.ensureInitialized('
        'rootIsolateToken: token) in background isolates. ($msg)',
      );
    }
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Failed to load Flutter asset "$assetKey": $msg',
    );
  } catch (e) {
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Failed to load Flutter asset "$assetKey": $e',
    );
  }
}

Future<DartResolvedSourceResult> _resolveAndroidContentOrResource(
  String uri,
  String scheme,
) async {
  try {
    final method =
        scheme == 'content' ? 'openContentFd' : 'openAndroidResource';
    final result = await _androidResolverChannel.invokeMapMethod<String, dynamic>(
      method,
      <String, dynamic>{'uri': uri},
    );
    if (result == null) {
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Android resolver returned null for "$uri".',
      );
    }

    final kind = result['kind'] as String?;
    final hintExt =
        (result['hintExt'] as String?) ?? extractExtensionHintFromSource(uri);
    if (kind == 'fd') {
      final fd = (result['fd'] as num?)?.toInt();
      if (fd == null || fd < 0) {
        return DartResolvedError(
          MapResult.errorFileNotFound,
          'Android resolver returned invalid file descriptor ($fd) for "$uri".',
        );
      }
      final offset = (result['offset'] as num?)?.toInt() ?? 0;
      final rawLen = (result['length'] as num?)?.toInt();
      final length = (rawLen != null && rawLen >= 0) ? rawLen : null;
      return DartResolvedFd(
        fd: fd,
        offset: offset,
        length: length,
        hintExt: hintExt,
      );
    }

    if (kind == 'bytes') {
      final bytes = result['bytes'];
      if (bytes is Uint8List && bytes.isNotEmpty) {
        return DartResolvedBytes(bytes, hintExt: hintExt);
      }
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Android resolver returned empty byte payload for "$uri".',
      );
    }

    return DartResolvedError(
      MapResult.errorInvalidArgs,
      'Android resolver returned unknown payload kind "$kind" for "$uri".',
    );
  } on PlatformException catch (e) {
    final code = switch (e.code) {
      'ACCESS_DENIED' || 'SECURITY_ERROR' => MapResult.errorAccessDenied,
      'FILE_NOT_FOUND' || 'RESOURCE_NOT_FOUND' => MapResult.errorFileNotFound,
      'INVALID_URI' || 'INVALID_ARGS' => MapResult.errorInvalidArgs,
      'UNSUPPORTED' => MapResult.errorUnsupported,
      _ => MapResult.errorGeneric,
    };
    return DartResolvedError(
      code,
      e.message ?? 'Failed to open Android URI "$uri" (${e.code}).',
    );
  } on MissingPluginException {
    return DartResolvedError(
      MapResult.errorUnsupported,
      'Android source resolver plugin is not registered for "$uri". Rebuild '
      'the Android application (`flutter clean` / cold restart) so '
      'MiniaudioPlayerPlugin is attached.',
    );
  } on StateError catch (e) {
    return DartResolvedError(
      MapResult.errorInvalidState,
      'Cannot resolve Android URI "$uri" in a background isolate because '
      'RootIsolateToken has not been initialized. Obtain RootIsolateToken.instance '
      'on the main isolate and pass it to '
      'MiniaudioPlayer.ensureInitialized(rootIsolateToken: token). ($e)',
    );
  } catch (e) {
    return DartResolvedError(
      MapResult.errorGeneric,
      'Unexpected failure resolving Android URI "$uri": $e',
    );
  }
}

/// Exposes Android MethodChannel URI resolution for VM unit testing.
@visibleForTesting
Future<DartResolvedSourceResult> resolveAndroidContentOrResourceForTest(
  String uri,
) {
  final scheme = extractUriScheme(uri) ?? 'content';
  return _resolveAndroidContentOrResource(uri, scheme);
}

/// Opens a writable detached POSIX file descriptor for an Android `content://` URI
/// (e.g. from Storage Access Framework or `MediaStore`).
///
/// Requires `Platform.isAndroid` and a valid [RootIsolateToken] when invoked from
/// a background isolate.
Future<int> openWritableAndroidContentFd(String uri) async {
  if (!Platform.isAndroid) {
    throw MiniaudioPlayerException(
      'Writable content:// URI "$uri" is only supported on Android.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  return _openWritableAndroidContentFdChannel(uri);
}

@visibleForTesting
Future<int> openWritableAndroidContentFdForTest(String uri) {
  return _openWritableAndroidContentFdChannel(uri);
}

Future<int> _openWritableAndroidContentFdChannel(String uri) async {
  try {
    final result = await _androidResolverChannel.invokeMapMethod<String, dynamic>(
      'openWritableContentFd',
      <String, dynamic>{'uri': uri},
    );
    final fd = (result?['fd'] as num?)?.toInt();
    if (fd == null || fd < 0) {
      throw MiniaudioPlayerException(
        'Android resolver returned invalid writable file descriptor ($fd) for "$uri".',
        errorCode: MapResult.errorFileNotFound,
      );
    }
    return fd;
  } on PlatformException catch (e) {
    final code = switch (e.code) {
      'ACCESS_DENIED' || 'SECURITY_ERROR' => MapResult.errorAccessDenied,
      'FILE_NOT_FOUND' || 'RESOURCE_NOT_FOUND' => MapResult.errorFileNotFound,
      'INVALID_URI' || 'INVALID_ARGS' => MapResult.errorInvalidArgs,
      'UNSUPPORTED' => MapResult.errorUnsupported,
      _ => MapResult.errorGeneric,
    };
    throw MiniaudioPlayerException(
      e.message ?? 'Failed to open writable Android content URI "$uri" (${e.code}).',
      errorCode: code,
    );
  } on MissingPluginException {
    throw MiniaudioPlayerException(
      'Android source resolver plugin is not registered for "$uri". Rebuild the '
      'Android application so MiniaudioPlayerPlugin is attached.',
      errorCode: MapResult.errorUnsupported,
    );
  } on StateError catch (e) {
    throw MiniaudioPlayerException(
      'Cannot resolve Android content URI "$uri" in a background isolate because '
      'RootIsolateToken has not been initialized. Obtain RootIsolateToken.instance '
      'on the main isolate and pass it to MiniaudioPlayer.ensureInitialized('
      'rootIsolateToken: token). ($e)',
      errorCode: MapResult.errorInvalidState,
    );
  }
}
