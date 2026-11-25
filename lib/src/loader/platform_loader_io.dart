import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;

import '../api/logger.dart';
import '../rust/frb_generated.dart';

/// Resolves and opens the native `miniaudio_player` dynamic library across all
/// Dart and Flutter execution environments.
///
/// Checks [customLibraryPath] and the `MINIAUDIO_PLAYER_LIB_PATH` environment
/// variable first, probes Native Assets and AOT bundle candidate directories,
/// and finally falls back to Flutter Rust Bridge's default loader.
Future<ExternalLibrary?> resolvePlatformExternalLibrary({
  String? customLibraryPath,
}) async {
  // 1. Explicit custom path or environment override.
  final overridePath =
      customLibraryPath ?? Platform.environment['MINIAUDIO_PLAYER_LIB_PATH'];
  if (overridePath != null && overridePath.trim().isNotEmpty) {
    final trimmed = overridePath.trim();
    MapLogger.debug('Opening native library from override path "$trimmed".');
    return ExternalLibrary.open(trimmed);
  }

  final libName = _platformLibraryFileName();

  // 2. Probe Native Assets hook & AOT bundle locations in deterministic order.
  for (final candidatePath in _nativeAssetCandidatePaths(libName)) {
    final file = File(candidatePath);
    if (!file.existsSync()) continue;
    try {
      final absPath = file.absolute.path;
      MapLogger.debug('Opening native library candidate "$absPath".');
      return ExternalLibrary.open(absPath);
    } catch (e) {
      // Continue probing if a candidate is for another architecture or unreadable.
      MapLogger.debug(
        'Failed to open native library candidate "${file.absolute.path}": $e',
      );
    }
  }

  // 3. Fall back to FRB's default loader (covers Android APK jniLibs,
  //    iOS/macOS Frameworks, and local rust/target/release/).
  MapLogger.debug(
    'Falling back to Flutter Rust Bridge default external library loader for "$libName".',
  );
  return await loadExternalLibrary(RustLib.kDefaultExternalLibraryLoaderConfig);
}

/// Builds an ordered list of candidate filesystem paths for [libName] based on
/// whether the current process is an AOT bundle or a test/JIT VM runner.
List<String> _nativeAssetCandidatePaths(String libName) {
  final paths = <String>[];
  var isFlutterTester = false;

  // A. Standalone AOT / Flutter Desktop app bundle paths (probed first when
  //    running as a compiled application rather than the Dart/Flutter test VM).
  try {
    final resolvedExe = File(Platform.resolvedExecutable);
    final exeName = p.basename(resolvedExe.path).toLowerCase();
    isFlutterTester =
        exeName == 'flutter_tester' || exeName == 'flutter_tester.exe';
    final isDartVm = exeName == 'dart' || exeName == 'dart.exe';
    if (!isFlutterTester && !isDartVm) {
      if (!Platform.isAndroid) {
        final exeDir = resolvedExe.parent.path;
        if (Platform.isMacOS || Platform.isIOS) {
          // Flutter macOS framework (`<app>.app/Contents/Frameworks/miniaudio_player.framework/miniaudio_player`).
          paths.add(
            p.normalize(
              p.join(
                exeDir,
                '..',
                'Frameworks',
                'miniaudio_player.framework',
                'miniaudio_player',
              ),
            ),
          );
          // Flutter iOS framework (`Runner.app/Frameworks/miniaudio_player.framework/miniaudio_player`).
          paths.add(
            p.join(
              exeDir,
              'Frameworks',
              'miniaudio_player.framework',
              'miniaudio_player',
            ),
          );
        }
        // Flutter Linux bundle (`<bundle>/lib/libminiaudio_player.so`).
        paths.add(p.join(exeDir, 'lib', libName));
        // `dart build cli` AOT bundle (`<bundle>/bin/../lib/...`).
        paths.add(p.normalize(p.join(exeDir, '..', 'lib', libName)));
        // Flutter Windows bundle (DLL sits directly beside the `.exe`).
        paths.add(p.join(exeDir, libName));
      }
      // Never probe workspace-relative CWD paths (`rust/target/`, `.dart_tool/`)
      // when running inside a compiled app bundle; let `loadExternalLibrary`
      // resolve `@rpath` / APK `jniLibs` / system search paths next.
      return paths;
    }
  } catch (e) {
    MapLogger.debug(
      'Could not inspect Platform.resolvedExecutable while probing native library paths: $e',
    );
  }

  final dartToolLib = p.join('.dart_tool', 'lib', libName);
  final flutterNativeAssetsLib = p.join(
    'build',
    'native_assets',
    Platform.operatingSystem,
    libName,
  );

  // B & C. Prioritize the directory actively written by the current test/JIT runner
  // (`flutter_tester` writes `build/native_assets/<os>/`; `dart` writes `.dart_tool/lib/`).
  if (isFlutterTester) {
    paths.add(flutterNativeAssetsLib);
    paths.add(dartToolLib);
  } else {
    paths.add(dartToolLib);
    paths.add(flutterNativeAssetsLib);
  }

  // D. Local workspace cargo target fallbacks (for direct cargo builds without hooks).
  for (final prefix in ['', '..']) {
    for (final profile in ['release', 'debug']) {
      paths.add(
        prefix.isEmpty
            ? p.join('rust', 'target', profile, libName)
            : p.join(prefix, 'rust', 'target', profile, libName),
      );
    }
  }

  return paths;
}

/// Returns the platform-specific shared library filename for the current OS.
///
/// Throws [UnsupportedError] on unrecognized operating systems.
String _platformLibraryFileName() {
  if (Platform.isLinux || Platform.isAndroid) {
    return 'libminiaudio_player.so';
  }
  if (Platform.isMacOS || Platform.isIOS) {
    return 'libminiaudio_player.dylib';
  }
  if (Platform.isWindows) {
    return 'miniaudio_player.dll';
  }
  MapLogger.error(
    'Unsupported operating system for native library resolution: ${Platform.operatingSystem}.',
  );
  throw UnsupportedError(
    'Unsupported operating system: ${Platform.operatingSystem}',
  );
}

/// Ensures the current Dart isolate is counted in the native [library] live
/// isolate counter before `RustLib.init` runs.
///
/// Prevents multi-isolate shutdown hangs in Flutter Rust Bridge 2.x.
void registerIsolateWithLibrary(ExternalLibrary library) {
  _loadedNativeLibrary ??= library.ffiDynamicLibrary;
  if (_isolateRegistration != null) return;
  try {
    final createShutdownCallback = library.ffiDynamicLibrary.lookupFunction<
        ffi.Pointer<ffi.NativeFinalizerFunction> Function(),
        ffi.Pointer<ffi.NativeFinalizerFunction>
            Function()>('frb_create_shutdown_callback');
    _isolateRegistration = _IsolateRegistration(createShutdownCallback());
    MapLogger.debug(
      'Registered current Dart isolate shutdown callback with native library.',
    );
  } catch (e) {
    // Non-fatal if symbol is absent in mock mode.
    MapLogger.debug(
      'Skipped isolate shutdown callback registration (symbol absent or unavailable): $e',
    );
  }
}

/// Cached reference to the native dynamic library loaded during engine setup.
ffi.DynamicLibrary? _loadedNativeLibrary;

/// Returns the native dynamic library bound during engine initialization, or
/// `null` if none has been registered yet.
ffi.DynamicLibrary? get loadedNativeDynamicLibrary => _loadedNativeLibrary;

/// Isolate-scoped sentinel keeping the native shutdown finalizer attached.
_IsolateRegistration? _isolateRegistration;

/// Finalizable token that triggers the native FRB shutdown callback when the
/// current Dart isolate exits.
final class _IsolateRegistration implements ffi.Finalizable {
  /// Creates an [_IsolateRegistration] bound to the native finalizer
  /// [callback].
  _IsolateRegistration(ffi.Pointer<ffi.NativeFinalizerFunction> callback)
      : _finalizer = ffi.NativeFinalizer(callback) {
    _finalizer.attach(this, ffi.Pointer.fromAddress(0));
  }

  /// Retained native finalizer handle so it remains active for the isolate
  /// lifetime.
  // ignore: unused_field
  final ffi.NativeFinalizer _finalizer;
}
