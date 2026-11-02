import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../../rust/frb_generated.dart';
import '../platform_backend.dart';

/// Private coordinator locating and initializing the native Rust FFI shared library.
abstract final class _NativeLibraryLoader {
  static Future<void>? _initFuture;

  static Future<void> ensureInitialized() async {
    if (RustLib.instance.initialized) return;
    await (_initFuture ??= _initializeRustLib());
  }

  static Future<void> _initializeRustLib() async {
    try {
      await RustLib.init();
      return;
    } catch (_) {
      final candidatePath = _findLocalSharedLibrary();
      if (candidatePath != null) {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(candidatePath),
        );
        return;
      }
      rethrow;
    }
  }

  static String? _findLocalSharedLibrary() {
    final libName = _platformLibraryName();
    final cwd = Directory.current.path;

    final hooksDir = Directory(
      '$cwd/.dart_tool/hooks_runner/shared/miniaudio_player/build',
    );
    if (hooksDir.existsSync()) {
      for (final entry in hooksDir.listSync().whereType<Directory>()) {
        final candidate = File('${entry.path}/$libName');
        if (candidate.existsSync()) return candidate.path;
      }
    }

    final targetCandidates = <String>[
      '$cwd/rust/target/release/$libName',
      '$cwd/rust/target/debug/$libName',
      '$cwd/../rust/target/release/$libName',
      '$cwd/../rust/target/debug/$libName',
    ];
    for (final path in targetCandidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static String _platformLibraryName() {
    if (Platform.isWindows) return 'miniaudio_player.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libminiaudio_player.dylib';
    return 'libminiaudio_player.so';
  }

  static String normalizePath(String rawPath) {
    final trimmed = rawPath.trim();
    if (trimmed.startsWith('file://')) {
      try {
        return Uri.parse(trimmed).toFilePath();
      } catch (_) {}
    }
    return trimmed;
  }
}

/// Ensures the `flutter_rust_bridge` native runtime is initialized.
Future<void> ensureRustInitialized() =>
    _NativeLibraryLoader.ensureInitialized();

/// Native FFI implementation of [PlayerBackend] backed by `RustPlayer`.
class NativePlayerBackend extends RustBridgePlayerBackend {
  NativePlayerBackend([dynamic _]);

  @override
  Future<void> ensureRuntimeInitialized() =>
      _NativeLibraryLoader.ensureInitialized();

  @override
  Uint8List? readLocalHeaderBytes(String source) {
    final normalized = _NativeLibraryLoader.normalizePath(source);
    if (normalized.startsWith('http://') ||
        normalized.startsWith('https://') ||
        normalized.startsWith('icy://') ||
        normalized.startsWith('asset:')) {
      return null;
    }
    try {
      final file = File(normalized);
      if (!file.existsSync()) return null;
      final raf = file.openSync();
      try {
        return raf.readSync(4096);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return null;
    }
  }
}

/// Native FFI implementation of [PlatformService] backed by `flutter_rust_bridge`.
class NativePlatformService extends RustBridgePlatformService {
  @override
  Future<void> ensureRuntimeInitialized() =>
      _NativeLibraryLoader.ensureInitialized();

  @override
  String normalizeLocalPath(String rawPath) =>
      _NativeLibraryLoader.normalizePath(rawPath);
}

PlayerBackend createPlayerBackend([dynamic player]) =>
    NativePlayerBackend(player);
PlatformService getPlatformService() => NativePlatformService();
