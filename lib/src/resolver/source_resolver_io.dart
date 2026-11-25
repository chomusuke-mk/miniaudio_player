/// Native `dart:io` source normalization and deferred URI resolver.
///
/// @docImport '../api/miniaudio_player.dart';
library;

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

import '../api/logger.dart';
import '../api/player_exception.dart';
import 'source_resolver_common.dart';
import 'ws_stream_provider.dart';

/// Method channel used on Android to open `content://` and
/// `android.resource://` descriptors or byte payloads.
const MethodChannel _androidResolverChannel = MethodChannel(
  'dev.chomusuke.miniaudio_player/source_resolver',
);

/// Returns whether assertions (Flutter debug mode) are enabled on this isolate.
bool _detectDebugMode() {
  var debug = false;
  assert(() {
    debug = true;
    return true;
  }());
  return debug;
}

/// Registers [token] so background isolates can invoke `'flutter/assets'` and
/// the Android `'dev.chomusuke.miniaudio_player/source_resolver'` channel.
///
/// Does nothing when [token] is `null`.
void registerSourceResolverIsolateToken(RootIsolateToken? token) {
  if (token == null) return;
  BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  MapLogger.debug(
    'Initialized BackgroundIsolateBinaryMessenger with RootIsolateToken.',
  );
}

/// Synchronously normalizes [rawUri] for native (Linux, Windows, macOS,
/// Android, and iOS) targets.
///
/// Delegates to [normalizeAudioSourceUri] with native platform flags.
NormalizedAudioSource normalizePlatformAudioSourceUri(String rawUri) {
  return normalizeAudioSourceUri(
    rawUri,
    isWeb: false,
    isWindows: Platform.isWindows,
    isAndroid: Platform.isAndroid,
    isDebug: _detectDebugMode(),
  );
}

/// Attempts fast, non-allocating disk resolution for [assetKey] inside desktop
/// `flutter_assets` bundles.
///
/// Checks `<exe>/data/flutter_assets` on Linux/Windows and
/// `<exe>/../Frameworks/App.framework/Resources/flutter_assets` on macOS.
/// Returns `null` on non-desktop targets or if the asset is not found on disk.
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
      MapLogger.verbose(
        'Found desktop flutter_assets file for "$assetKey" at "$candidate".',
      );
      return candidate;
    }
  }
  return null;
}

/// Attempts synchronous resolution for [normalizedSource] via local disk
/// assets in desktop `flutter_assets`.
///
/// Returns `null` when asynchronous platform channels or bundle loaders are
/// required.
DartResolvedSourceResult? tryResolveSourceSync(String normalizedSource) {
  final scheme = extractUriScheme(normalizedSource);
  if (scheme == 'asset') {
    final key = extractRelativeAssetKey(normalizedSource);
    final diskPath = _tryFindDesktopFlutterAssetFile(key);
    if (diskPath != null) {
      MapLogger.debug(
        'Synchronously resolved desktop asset "$normalizedSource" -> "$diskPath".',
      );
      return DartResolvedPath(diskPath);
    }
  }
  return null;
}

/// Asynchronously resolves `asset://`, `content://`, `android.resource://`,
/// `ws://`, and `wss://` [normalizedSource] values on native targets.
///
/// Forwards optional [headers] and [isStaticAnalysis] to
/// [resolveWebSocketStream] when resolving WebSocket streams.
Future<DartResolvedSourceResult> resolveSourceAsync(
  String normalizedSource, {
  Map<String, String>? headers,
  bool isStaticAnalysis = false,
}) async {
  final scheme = extractUriScheme(normalizedSource);
  MapLogger.debug(
    'Resolving native deferred source "$normalizedSource" (scheme=$scheme, '
    'isStaticAnalysis=$isStaticAnalysis).',
  );
  switch (scheme) {
    case 'asset':
      return _resolveAssetNative(normalizedSource);
    case 'content':
    case 'android.resource':
      if (!Platform.isAndroid) {
        MapLogger.warn(
          'Rejected Android-only URI scheme "$scheme://" for '
          '"$normalizedSource" on ${Platform.operatingSystem}.',
        );
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
      MapLogger.warn(
        'Unsupported deferred source URI "$normalizedSource" on native target.',
      );
      return DartResolvedError(
        MapResult.errorUnsupported,
        'Unsupported deferred source URI "$normalizedSource".',
      );
  }
}

/// Returns whether a Flutter [ServicesBinding] is active on the current
/// isolate.
bool _hasActiveServicesBinding() {
  try {
    ServicesBinding.instance;
    return true;
  } on FlutterError catch (e) {
    MapLogger.verbose(
      'ServicesBinding inactive on current isolate ($e); using '
      'BackgroundIsolateBinaryMessenger.',
    );
    return false;
  } catch (e) {
    MapLogger.verbose(
      'ServicesBinding probe failed ($e); using '
      'BackgroundIsolateBinaryMessenger.',
    );
    return false;
  }
}

/// Resolves an `asset://` [normalizedSource] to a desktop file path or raw
/// bundle bytes via [rootBundle] or [BackgroundIsolateBinaryMessenger].
Future<DartResolvedSourceResult> _resolveAssetNative(
  String normalizedSource,
) async {
  final assetKey = extractRelativeAssetKey(normalizedSource);
  if (assetKey.isEmpty || assetKey.split('/').contains('..')) {
    MapLogger.warn('Invalid asset key in "$normalizedSource".');
    return DartResolvedError(
      MapResult.errorInvalidArgs,
      'Invalid asset key in "$normalizedSource".',
    );
  }

  final diskPath = _tryFindDesktopFlutterAssetFile(assetKey);
  if (diskPath != null) {
    MapLogger.debug('Resolved asset "$assetKey" to disk path "$diskPath".');
    return DartResolvedPath(diskPath);
  }

  final extHint = extractExtensionHintFromSource(assetKey);
  try {
    if (_hasActiveServicesBinding()) {
      final data = await rootBundle.load(assetKey);
      MapLogger.debug(
        'Loaded Flutter asset "$assetKey" via rootBundle '
        '(${data.lengthInBytes} bytes, hintExt=$extHint).',
      );
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
      MapLogger.warn('Flutter asset "$assetKey" not found on flutter/assets.');
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Flutter asset not found: "$assetKey". Ensure it is declared under '
        'flutter.assets in pubspec.yaml.',
      );
    }
    MapLogger.debug(
      'Loaded Flutter asset "$assetKey" via BackgroundIsolateBinaryMessenger '
      '(${data.lengthInBytes} bytes, hintExt=$extHint).',
    );
    return DartResolvedBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      hintExt: extHint,
    );
  } on StateError catch (e) {
    MapLogger.error(
      'Failed loading asset "$normalizedSource" without RootIsolateToken: $e',
    );
    return DartResolvedError(
      MapResult.errorInvalidState,
      'Cannot load Flutter asset "$normalizedSource" in a background isolate '
      'because RootIsolateToken has not been initialized. Obtain '
      'RootIsolateToken.instance on the main isolate and pass it to '
      'MiniaudioPlayer.ensureInitialized(rootIsolateToken: token). ($e)',
    );
  } on FlutterError catch (e) {
    MapLogger.error('FlutterError loading asset "$assetKey": ${e.message}');
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
    MapLogger.error('Unexpected error loading asset "$assetKey": $e');
    return DartResolvedError(
      MapResult.errorFileNotFound,
      'Failed to load Flutter asset "$assetKey": $e',
    );
  }
}

/// Resolves an Android `content://` or `android.resource://` [uri] with
/// parsed [scheme] via [_androidResolverChannel].
Future<DartResolvedSourceResult> _resolveAndroidContentOrResource(
  String uri,
  String scheme,
) async {
  try {
    final method =
        scheme == 'content' ? 'openContentFd' : 'openAndroidResource';
    final result =
        await _androidResolverChannel.invokeMapMethod<String, dynamic>(
      method,
      <String, dynamic>{'uri': uri},
    );
    if (result == null) {
      MapLogger.warn('Android resolver returned null for "$uri".');
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
        MapLogger.warn(
          'Android resolver returned invalid fd=$fd for "$uri".',
        );
        return DartResolvedError(
          MapResult.errorFileNotFound,
          'Android resolver returned invalid file descriptor ($fd) for "$uri".',
        );
      }
      final offset = (result['offset'] as num?)?.toInt() ?? 0;
      final rawLen = (result['length'] as num?)?.toInt();
      final length = (rawLen != null && rawLen >= 0) ? rawLen : null;
      MapLogger.debug(
        'Resolved Android URI "$uri" -> fd=$fd (offset=$offset, '
        'length=$length, hintExt=$hintExt).',
      );
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
        MapLogger.debug(
          'Resolved Android URI "$uri" -> ${bytes.length} bytes '
          '(hintExt=$hintExt).',
        );
        return DartResolvedBytes(bytes, hintExt: hintExt);
      }
      MapLogger.warn(
        'Android resolver returned empty byte payload for "$uri".',
      );
      return DartResolvedError(
        MapResult.errorFileNotFound,
        'Android resolver returned empty byte payload for "$uri".',
      );
    }

    MapLogger.warn(
      'Android resolver returned unknown payload kind "$kind" for "$uri".',
    );
    return DartResolvedError(
      MapResult.errorInvalidArgs,
      'Android resolver returned unknown payload kind "$kind" for "$uri".',
    );
  } on PlatformException catch (e) {
    MapLogger.error(
      'Android PlatformException resolving "$uri" (${e.code}): ${e.message}',
    );
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
  } on MissingPluginException catch (e) {
    MapLogger.error(
      'MissingPluginException resolving Android URI "$uri": $e',
    );
    return DartResolvedError(
      MapResult.errorUnsupported,
      'Android source resolver plugin is not registered for "$uri". Rebuild '
      'the Android application (`flutter clean` / cold restart) so '
      'MiniaudioPlayerPlugin is attached.',
    );
  } on StateError catch (e) {
    MapLogger.error(
      'StateError resolving Android URI "$uri" without RootIsolateToken: $e',
    );
    return DartResolvedError(
      MapResult.errorInvalidState,
      'Cannot resolve Android URI "$uri" in a background isolate because '
      'RootIsolateToken has not been initialized. Obtain RootIsolateToken.instance '
      'on the main isolate and pass it to '
      'MiniaudioPlayer.ensureInitialized(rootIsolateToken: token). ($e)',
    );
  } catch (e) {
    MapLogger.error('Unexpected failure resolving Android URI "$uri": $e');
    return DartResolvedError(
      MapResult.errorGeneric,
      'Unexpected failure resolving Android URI "$uri": $e',
    );
  }
}

/// Exposes Android [MethodChannel] resolution of [uri] for VM unit testing.
@visibleForTesting
Future<DartResolvedSourceResult> resolveAndroidContentOrResourceForTest(
  String uri,
) {
  final scheme = extractUriScheme(uri) ?? 'content';
  return _resolveAndroidContentOrResource(uri, scheme);
}

/// Opens a writable detached POSIX file descriptor for an Android `content://`
/// [uri], such as from Storage Access Framework or `MediaStore`.
///
/// Requires Android and a registered [RootIsolateToken] when invoked from a
/// background isolate. Throws a [MiniaudioPlayerException] if invoked outside
/// Android or if the platform channel rejects [uri].
Future<int> openWritableAndroidContentFd(String uri) async {
  if (!Platform.isAndroid) {
    MapLogger.warn(
      'Rejected writable content:// URI "$uri" on ${Platform.operatingSystem}.',
    );
    throw MiniaudioPlayerException(
      'Writable content:// URI "$uri" is only supported on Android.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  return _openWritableAndroidContentFdChannel(uri);
}

/// Exposes [_openWritableAndroidContentFdChannel] for [uri] in VM unit tests.
@visibleForTesting
Future<int> openWritableAndroidContentFdForTest(String uri) {
  return _openWritableAndroidContentFdChannel(uri);
}

/// Invokes `openWritableContentFd` on [_androidResolverChannel] for [uri].
///
/// Maps channel exceptions and invalid file descriptors into deterministic
/// [MiniaudioPlayerException] errors.
Future<int> _openWritableAndroidContentFdChannel(String uri) async {
  try {
    final result =
        await _androidResolverChannel.invokeMapMethod<String, dynamic>(
      'openWritableContentFd',
      <String, dynamic>{'uri': uri},
    );
    final fd = (result?['fd'] as num?)?.toInt();
    if (fd == null || fd < 0) {
      MapLogger.error(
        'Android resolver returned invalid writable fd=$fd for "$uri".',
      );
      throw MiniaudioPlayerException(
        'Android resolver returned invalid writable file descriptor ($fd) for "$uri".',
        errorCode: MapResult.errorFileNotFound,
      );
    }
    MapLogger.debug('Opened writable Android content fd=$fd for "$uri".');
    return fd;
  } on PlatformException catch (e) {
    MapLogger.error(
      'Android PlatformException opening writable "$uri" (${e.code}): ${e.message}',
    );
    final code = switch (e.code) {
      'ACCESS_DENIED' || 'SECURITY_ERROR' => MapResult.errorAccessDenied,
      'FILE_NOT_FOUND' || 'RESOURCE_NOT_FOUND' => MapResult.errorFileNotFound,
      'INVALID_URI' || 'INVALID_ARGS' => MapResult.errorInvalidArgs,
      'UNSUPPORTED' => MapResult.errorUnsupported,
      _ => MapResult.errorGeneric,
    };
    throw MiniaudioPlayerException(
      e.message ??
          'Failed to open writable Android content URI "$uri" (${e.code}).',
      errorCode: code,
    );
  } on MissingPluginException catch (e) {
    MapLogger.error(
      'MissingPluginException opening writable Android URI "$uri": $e',
    );
    throw MiniaudioPlayerException(
      'Android source resolver plugin is not registered for "$uri". Rebuild the '
      'Android application so MiniaudioPlayerPlugin is attached.',
      errorCode: MapResult.errorUnsupported,
    );
  } on StateError catch (e) {
    MapLogger.error(
      'StateError opening writable Android URI "$uri" without RootIsolateToken: $e',
    );
    throw MiniaudioPlayerException(
      'Cannot resolve Android content URI "$uri" in a background isolate because '
      'RootIsolateToken has not been initialized. Obtain RootIsolateToken.instance '
      'on the main isolate and pass it to MiniaudioPlayer.ensureInitialized('
      'rootIsolateToken: token). ($e)',
      errorCode: MapResult.errorInvalidState,
    );
  }
}
