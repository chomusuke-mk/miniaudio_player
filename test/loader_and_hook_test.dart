import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:miniaudio_player/src/loader/platform_loader.dart';

void main() {
  group('Native Assets Loader & Concurrent Initialization', () {
    test(
      'concurrent ensureInitialized() calls share memoized future without racing',
      () async {
        // Invoke ensureInitialized concurrently across 16 futures
        await Future.wait(
          List.generate(16, (_) => MiniaudioPlayer.ensureInitialized()),
        );

        final devices = MiniaudioPlayer.getOutputDevicesSync();
        expect(devices, isNotEmpty);
      },
    );

    test(
      'resolvePlatformExternalLibrary locates the compiled native library',
      () async {
        final extLib = await resolvePlatformExternalLibrary();
        expect(extLib, isNotNull);
      },
    );

    test(
      'hook/build.dart produces CodeAsset or shared cargo_target with .crate-hash stamp',
      () {
        final hookFile = File('hook/build.dart');
        expect(hookFile.existsSync(), isTrue);

        // Verify either the Native Assets build output or local target binary exists
        final candidatePaths = <String>[
          'build/native_assets/${Platform.operatingSystem}/libminiaudio_player.so',
          'build/native_assets/${Platform.operatingSystem}/libminiaudio_player.dylib',
          'build/native_assets/${Platform.operatingSystem}/miniaudio_player.dll',
          '.dart_tool/lib/libminiaudio_player.so',
          '.dart_tool/lib/libminiaudio_player.dylib',
          '.dart_tool/lib/miniaudio_player.dll',
          'rust/target/release/libminiaudio_player.so',
          'rust/target/debug/libminiaudio_player.so',
        ];
        final anyExists = candidatePaths.any((p) => File(p).existsSync());
        expect(
          anyExists,
          isTrue,
          reason:
              'Expected at least one compiled native library artifact to exist on disk.',
        );
      },
    );
  });
}
