import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final packageName = input.packageName;
    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;

    final String libName = _dylibFileName(targetOS, packageName);
    final outLibFile = File.fromUri(input.outputDirectory.resolve(libName));

    final cargoExe = _findCargo();
    final rustDir = Directory.fromUri(input.packageRoot.resolve('rust'));

    if (cargoExe != null && rustDir.existsSync()) {
      final targetTriple = _resolveTargetTriple(targetOS, targetArch);
      final isHost = _isHost(targetOS, targetArch);

      final buildArgs = [
        'build',
        '--release',
        '--manifest-path',
        rustDir.uri.resolve('Cargo.toml').toFilePath(),
      ];

      if (!isHost && targetTriple.isNotEmpty) {
        buildArgs.addAll(['--target', targetTriple]);
      }

      final cargoEnv = Map<String, String>.from(Platform.environment);
      final home = Platform.environment['HOME'] ?? '';
      if (home.isNotEmpty) {
        final cargoBin = '$home/.cargo/bin';
        final curPath = cargoEnv['PATH'] ?? '';
        if (!curPath.contains(cargoBin)) {
          cargoEnv['PATH'] = '$cargoBin:$curPath';
        }
      }

      final res = Process.runSync(
        cargoExe,
        buildArgs,
        workingDirectory: input.packageRoot.toFilePath(),
        environment: cargoEnv,
      );

      if (res.exitCode != 0) {
        throw ProcessException(
          cargoExe,
          buildArgs,
          'Cargo build failed:\n${res.stdout}\n${res.stderr}',
          res.exitCode,
        );
      }

      final targetSubdir = (!isHost && targetTriple.isNotEmpty)
          ? 'target/$targetTriple/release'
          : 'target/release';

      final builtFile = File.fromUri(rustDir.uri.resolve('$targetSubdir/$libName'));
      if (builtFile.existsSync()) {
        builtFile.copySync(outLibFile.path);
      } else {
        // Fallback check on Linux/Unix .so naming
        final altSo = File.fromUri(rustDir.uri.resolve('$targetSubdir/libminiaudio_player.so'));
        if (altSo.existsSync()) {
          altSo.copySync(outLibFile.path);
        } else {
          throw StateError('Built library not found at: ${builtFile.path}');
        }
      }
    } else {
      // Prebuilt library fallback from package directory
      final prebuiltFile = File.fromUri(input.packageRoot.resolve('lib/src/bin/$libName'));
      if (prebuiltFile.existsSync()) {
        prebuiltFile.copySync(outLibFile.path);
      } else {
        throw StateError(
          'Cargo is not available and prebuilt library was not found at ${prebuiltFile.path}',
        );
      }
    }

    final srcDir = Directory.fromUri(rustDir.uri.resolve('src'));
    if (srcDir.existsSync()) {
      for (final entity in srcDir.listSync(recursive: true)) {
        if (entity is File) {
          output.dependencies.add(entity.uri);
        }
      }
    }
    output.dependencies.add(rustDir.uri.resolve('Cargo.toml'));
    output.dependencies.add(rustDir.uri.resolve('build.rs'));

    output.assets.code.add(
      CodeAsset(
        package: packageName,
        name: '${packageName}_bindings_generated.dart',
        linkMode: DynamicLoadingBundled(),
        file: outLibFile.uri,
      ),
    );
  });
}

String _dylibFileName(OS os, String name) {
  if (os == OS.windows) return '$name.dll';
  if (os == OS.macOS || os == OS.iOS) return 'lib$name.dylib';
  return 'lib$name.so';
}

String? _findCargo() {
  final home = Platform.environment['HOME'] ?? '';
  if (home.isNotEmpty) {
    final candidate = File('$home/.cargo/bin/cargo');
    if (candidate.existsSync()) {
      return candidate.path;
    }
  }
  // Try resolving from PATH
  final res = Process.runSync('which', ['cargo']);
  if (res.exitCode == 0) {
    final path = (res.stdout as String).trim();
    if (path.isNotEmpty && File(path).existsSync()) {
      return path;
    }
  }
  return null;
}

bool _isHost(OS os, Architecture arch) {
  if (os != OS.current) return false;
  // Match current host arch
  final hostArch = _hostArchitecture();
  return hostArch == arch;
}

Architecture _hostArchitecture() {
  final archStr = Platform.version.toLowerCase();
  if (archStr.contains('arm64') || archStr.contains('aarch64')) {
    return Architecture.arm64;
  }
  if (archStr.contains('x64') || archStr.contains('x86_64')) {
    return Architecture.x64;
  }
  return Architecture.x64;
}

String _resolveTargetTriple(OS os, Architecture arch) {
  if (os == OS.linux) {
    if (arch == Architecture.x64) return 'x86_64-unknown-linux-gnu';
    if (arch == Architecture.arm64) return 'aarch64-unknown-linux-gnu';
  } else if (os == OS.android) {
    if (arch == Architecture.arm64) return 'aarch64-linux-android';
    if (arch == Architecture.arm) return 'armv7-linux-androideabi';
    if (arch == Architecture.x64) return 'x86_64-linux-android';
    if (arch == Architecture.ia32) return 'i686-linux-android';
  } else if (os == OS.windows) {
    if (arch == Architecture.x64) return 'x86_64-pc-windows-msvc';
  } else if (os == OS.macOS) {
    if (arch == Architecture.arm64) return 'aarch64-apple-darwin';
    if (arch == Architecture.x64) return 'x86_64-apple-darwin';
  } else if (os == OS.iOS) {
    if (arch == Architecture.arm64) return 'aarch64-apple-ios';
    if (arch == Architecture.x64) return 'x86_64-apple-ios';
  }
  return '';
}
