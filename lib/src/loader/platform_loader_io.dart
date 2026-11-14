import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';
import 'package:path/path.dart' as p;

import '../rust/frb_generated.dart';

/// Resolves and opens the native `miniaudio_player` dynamic library across all
/// Dart and Flutter execution environments (`dart test`, `flutter test`,
/// `dart run`, `dart build cli`, `flutter run`, and desktop/mobile AOT bundles).
Future<ExternalLibrary?> resolvePlatformExternalLibrary({
  String? customLibraryPath,
}) async {
  // 1. Explicit custom path or environment override
  final overridePath =
      customLibraryPath ?? Platform.environment['MINIAUDIO_PLAYER_LIB_PATH'];
  if (overridePath != null && overridePath.trim().isNotEmpty) {
    return ExternalLibrary.open(overridePath.trim());
  }

  final libName = _platformLibraryFileName();

  // 2. Probe Native Assets hook & AOT bundle locations in deterministic order
  for (final candidatePath in _nativeAssetCandidatePaths(libName)) {
    final file = File(candidatePath);
    if (!file.existsSync()) continue;
    try {
      return ExternalLibrary.open(file.absolute.path);
    } catch (_) {
      // Continue probing if a candidate is for another architecture or unreadable.
    }
  }

  // 3. Fall back to FRB's default loader (covers Android APK jniLibs,
  //    iOS/macOS Frameworks, and local rust/target/release/).
  return await loadExternalLibrary(RustLib.kDefaultExternalLibraryLoaderConfig);
}

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
      final exeDir = resolvedExe.parent.path;
      // Flutter Linux bundle (`<bundle>/lib/libminiaudio_player.so`)
      paths.add(p.join(exeDir, 'lib', libName));
      // `dart build cli` AOT bundle (`<bundle>/bin/../lib/...`)
      paths.add(p.normalize(p.join(exeDir, '..', 'lib', libName)));
      // Flutter Windows bundle (DLL sits directly beside the `.exe`)
      paths.add(p.join(exeDir, libName));
    }
  } catch (_) {}

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

  // D. Local workspace cargo target fallbacks (for direct cargo builds without hooks)
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
  throw UnsupportedError(
    'Unsupported operating system: ${Platform.operatingSystem}',
  );
}

/// Ensures the current Dart isolate is counted in the native library's live
/// isolate counter before `RustLib.init()` runs (preventing multi-isolate
/// shutdown hangs in flutter_rust_bridge 2.x).
void registerIsolateWithLibrary(ExternalLibrary library) {
  if (_isolateRegistration != null) return;
  try {
    final createShutdownCallback = library.ffiDynamicLibrary.lookupFunction<
        ffi.Pointer<ffi.NativeFinalizerFunction> Function(),
        ffi.Pointer<ffi.NativeFinalizerFunction>
            Function()>('frb_create_shutdown_callback');
    _isolateRegistration = _IsolateRegistration(createShutdownCallback());
  } catch (_) {
    // Non-fatal if symbol is absent in mock mode.
  }
}

_IsolateRegistration? _isolateRegistration;

final class _IsolateRegistration implements ffi.Finalizable {
  _IsolateRegistration(ffi.Pointer<ffi.NativeFinalizerFunction> callback)
      : _finalizer = ffi.NativeFinalizer(callback) {
    _finalizer.attach(this, ffi.Pointer.fromAddress(0));
  }

  // ignore: unused_field
  final ffi.NativeFinalizer _finalizer;
}
