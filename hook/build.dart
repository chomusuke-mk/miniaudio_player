import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'src/binary_validator.dart';
import 'src/cargo_env.dart';
import 'src/depfile_parser.dart';
import 'src/gzip_extractor.dart';
import 'src/target_triple.dart';

const _packageName = 'miniaudio_player';
const _defaultVersion = '4.0.0';
const _githubRepo = 'chomusuke-mk/miniaudio_player';
const _cacheCompleteMarker = '.download-complete';
const _crateHashMarker = '.crate-hash';

/// Embedded SHA-256 checksums for official `.gz` GitHub Release binaries.
///
/// Populated automatically by `tool/update_release_hashes.dart` during the CI
/// release workflow before `dart pub publish`. When an entry is present here,
/// the hook verifies the downloaded `.gz` against this immutable compile-time
/// hash; otherwise it fetches and verifies `checksums.sha256` from the release.
const Map<String, String> _embeddedReleaseHashes = <String, String>{
  // 'miniaudio_player-v4.0.0-aarch64-linux-android.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-armv7-linux-androideabi.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-x86_64-linux-android.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-i686-linux-android.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-aarch64-apple-ios.dylib.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-aarch64-apple-ios-sim.dylib.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-x86_64-apple-ios.dylib.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-aarch64-apple-darwin.dylib.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-x86_64-apple-darwin.dylib.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-x86_64-unknown-linux-gnu.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-aarch64-unknown-linux-gnu.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-i686-unknown-linux-gnu.so.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-x86_64-pc-windows-msvc.dll.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-aarch64-pc-windows-msvc.dll.gz': '<sha256>',
  // 'miniaudio_player-v4.0.0-i686-pc-windows-msvc.dll.gz': '<sha256>',
};

const _retryDelays = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Track hook files as baseline dependencies.
    output.dependencies.add(input.packageRoot.resolve('hook/build.dart'));
    output.dependencies.add(input.packageRoot.resolve('pubspec.yaml'));

    if (!input.config.buildCodeAssets) {
      return;
    }

    final version = _resolvePackageVersion(input);
    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;
    final targetArch = codeConfig.targetArchitecture;
    final iosSdk = targetOS == OS.iOS ? codeConfig.iOS.targetSdk : null;

    final rustTriple = resolveRustTriple(targetOS, targetArch, iosSdk);
    final libFileName = targetOS.dylibFileName(_packageName);
    final finalOutFile = File.fromUri(
      input.outputDirectory.resolve(libFileName),
    );
    await finalOutFile.parent.create(recursive: true);

    // -------------------------------------------------------------------------
    // Priority 1: Explicit custom binary path (Env var or pubspec user_defines)
    // -------------------------------------------------------------------------
    final customPath = _resolveCustomLibPath(input);
    if (customPath != null) {
      final sourceFile = File(customPath);
      if (!sourceFile.existsSync()) {
        throw BuildError(
          message:
              'Custom native library specified at "$customPath" does not exist.',
        );
      }
      validateBinaryArchitectureOrThrow(
        file: sourceFile,
        targetOS: targetOS,
        targetArch: targetArch,
        sourceDescription: 'MINIAUDIO_PLAYER_LIB_PATH / user_defines.path',
      );
      await sourceFile.copy(finalOutFile.path);
      output.dependencies.add(sourceFile.uri);
      _registerCodeAsset(input, output, finalOutFile.uri);
      return;
    }

    final forceSource = _shouldForceSourceBuild(input);
    final isRepoContributor = _isWorkingInPackageRepo(input);

    // -------------------------------------------------------------------------
    // Priority 2 & 3: Local Cargo Build (Forced or Contributor In-Repo Mode)
    // -------------------------------------------------------------------------
    if (forceSource || isRepoContributor) {
      await _buildFromRustSource(
        input: input,
        output: output,
        rustTriple: rustTriple,
        libFileName: libFileName,
        destination: finalOutFile,
      );
      _registerCodeAsset(input, output, finalOutFile.uri);
      return;
    }

    // -------------------------------------------------------------------------
    // Priority 4: Prebuilt `.gz` Binary Download from GitHub Releases (Default)
    // -------------------------------------------------------------------------
    try {
      await _acquirePrebuiltBinary(
        input: input,
        version: version,
        rustTriple: rustTriple,
        libFileName: libFileName,
        destination: finalOutFile,
      );
      _registerCodeAsset(input, output, finalOutFile.uri);
      return;
    } on BuildError {
      // Security / checksum / binary architecture mismatch must NEVER fall back silently.
      rethrow;
    } catch (downloadErr) {
      // -----------------------------------------------------------------------
      // Priority 5: Automatic Fallback to Local Cargo Build if Rust is present
      // -----------------------------------------------------------------------
      final rustDir = Directory.fromUri(input.packageRoot.resolve('rust/'));
      final cargoExe = findExecutable('cargo');
      if (rustDir.existsSync() && cargoExe != null) {
        stderr.writeln(
          '[miniaudio_player] Prebuilt binary download unavailable ($downloadErr). '
          'Falling back to local Cargo compilation for $rustTriple...',
        );
        await _buildFromRustSource(
          input: input,
          output: output,
          rustTriple: rustTriple,
          libFileName: libFileName,
          destination: finalOutFile,
        );
        _registerCodeAsset(input, output, finalOutFile.uri);
        return;
      }

      throw InfraError(
        message:
            'Failed to download prebuilt miniaudio_player v$version binary for '
            '$rustTriple, and no local Rust toolchain (cargo) was found for '
            'fallback compilation.\n'
            'Cause: $downloadErr\n'
            'To fix:\n'
            '  1. Check internet connectivity to github.com/$_githubRepo/releases, OR\n'
            '  2. Provide a local binary via hooks.user_defines.miniaudio_player.path in pubspec.yaml, OR\n'
            '  3. Install Rust (https://rustup.rs) and set hooks.user_defines.miniaudio_player.use_source_build: true.',
      );
    }
  });
}

void _registerCodeAsset(
  BuildInput input,
  BuildOutputBuilder output,
  Uri fileUri,
) {
  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: _packageName,
      linkMode: DynamicLoadingBundled(),
      file: fileUri,
    ),
  );
}

// =============================================================================
// Configuration & Mode Detection Helpers
// =============================================================================

String _resolvePackageVersion(BuildInput input) {
  try {
    final pubspecFile = File.fromUri(input.packageRoot.resolve('pubspec.yaml'));
    if (pubspecFile.existsSync()) {
      for (final line in pubspecFile.readAsLinesSync()) {
        final match = RegExp(r'^version:\s*([^\s#]+)').firstMatch(line.trim());
        if (match != null) {
          return match.group(1)!;
        }
      }
    }
  } catch (_) {}
  return _defaultVersion;
}

String? _resolveCustomLibPath(BuildInput input) {
  final envPath = Platform.environment['MINIAUDIO_PLAYER_LIB_PATH'];
  if (envPath != null && envPath.trim().isNotEmpty) {
    return envPath.trim();
  }
  final userPath = input.userDefines['path'];
  if (userPath is String && userPath.trim().isNotEmpty) {
    final resolved = input.packageRoot.resolve(userPath.trim());
    return File.fromUri(resolved).path;
  }
  return null;
}

bool _shouldForceSourceBuild(BuildInput input) {
  final envForce = Platform.environment['MINIAUDIO_PLAYER_BUILD_FROM_SOURCE'];
  if (envForce == '1' || envForce?.toLowerCase() == 'true') {
    return true;
  }
  final userForce = input.userDefines['use_source_build'];
  if (userForce == true || userForce == 'true' || userForce == '1') {
    return true;
  }
  return false;
}

/// Detects if the hook is running inside a git checkout of miniaudio_player
/// itself (as opposed to `~/.pub-cache/hosted/pub.dev/...`).
bool _isWorkingInPackageRepo(BuildInput input) {
  final pkgPath = input.packageRoot.toFilePath();
  final segments = p.split(pkgPath);
  if (segments.contains('.pub-cache') ||
      segments.contains('pub.dartlang.org')) {
    return false;
  }
  final gitDir = Directory.fromUri(input.packageRoot.resolve('.git'));
  final rustCargo = File.fromUri(input.packageRoot.resolve('rust/Cargo.toml'));
  return gitDir.existsSync() && rustCargo.existsSync();
}

String _resolveDownloadBaseUrl(BuildInput input, String version) {
  final envUrl = Platform.environment['MINIAUDIO_PLAYER_DOWNLOAD_BASE_URL'];
  if (envUrl != null && envUrl.trim().isNotEmpty) {
    return envUrl.trim().replaceAll(RegExp(r'/+$'), '');
  }
  final userUrl = input.userDefines['download_base_url'];
  if (userUrl is String && userUrl.trim().isNotEmpty) {
    return userUrl.trim().replaceAll(RegExp(r'/+$'), '');
  }
  return 'https://github.com/$_githubRepo/releases/download/v$version';
}

Future<T> _withExclusiveLock<T>(
  File lockFile,
  Future<T> Function() action,
) async {
  await lockFile.parent.create(recursive: true);
  final raf = await lockFile.open(mode: FileMode.write);
  try {
    await raf.lock(FileLock.exclusive);
    return await action();
  } finally {
    try {
      await raf.unlock();
    } catch (_) {}
    await raf.close();
  }
}

// =============================================================================
// Prebuilt Binary Download (.gz), Atomic Caching, SHA-256 & Header Verification
// =============================================================================

Future<void> _acquirePrebuiltBinary({
  required BuildInput input,
  required String version,
  required String rustTriple,
  required String libFileName,
  required File destination,
}) async {
  final codeConfig = input.config.code;
  final archiveName = prebuiltArchiveName(
    packageName: _packageName,
    version: version,
    rustTriple: rustTriple,
    libFileName: libFileName,
  );
  final baseUrl = _resolveDownloadBaseUrl(input, version);
  final downloadUrl = '$baseUrl/$archiveName';

  final cacheDir = Directory.fromUri(
    input.outputDirectoryShared.resolve('prebuilt-v$version-$rustTriple/'),
  );
  final lockFile = File.fromUri(
    input.outputDirectoryShared.resolve('.lock_prebuilt_$rustTriple'),
  );
  final cachedLib = File(p.join(cacheDir.path, libFileName));
  final completeMarker = File(p.join(cacheDir.path, _cacheCompleteMarker));

  await _withExclusiveLock(lockFile, () async {
    // Fast path: reuse verified shared cache entry if base URL, embedded hash & header match.
    if (completeMarker.existsSync() && cachedLib.existsSync()) {
      final markerLines = completeMarker.readAsLinesSync();
      final markerHash =
          markerLines.isNotEmpty ? markerLines[0].trim().toLowerCase() : '';
      final markerUrl = markerLines.length > 1 ? markerLines[1].trim() : '';
      final embedded = _embeddedReleaseHashes[archiveName];
      final embeddedMatches =
          embedded == null || markerHash == embedded.toLowerCase();

      if (embeddedMatches && markerUrl == baseUrl) {
        try {
          validateBinaryArchitectureOrThrow(
            file: cachedLib,
            targetOS: codeConfig.targetOS,
            targetArch: codeConfig.targetArchitecture,
            sourceDescription: 'cached prebuilt $libFileName',
          );
          await cachedLib.copy(destination.path);
          return;
        } catch (_) {
          // Invalid/corrupted cache entry — wipe and re-download below.
        }
      }
      try {
        completeMarker.deleteSync();
      } catch (_) {}
      try {
        cachedLib.deleteSync();
      } catch (_) {}
    }

    await cacheDir.create(recursive: true);
    final expectedSha256 = await _resolveExpectedSha256(
      baseUrl,
      archiveName,
      version,
    );

    final tmpArchive = File(p.join(cacheDir.path, '$archiveName.tmp.$pid'));
    final tmpUnpacked = File(p.join(cacheDir.path, '$libFileName.tmp.$pid'));
    try {
      await _downloadWithRetry(Uri.parse(downloadUrl), tmpArchive);
      await _verifyFileSha256(tmpArchive, expectedSha256, archiveName);

      // Decompress single-file `.gz` natively using `dart:io` `gzip` codec.
      await decompressGzipFile(tmpArchive, tmpUnpacked);

      // Verify binary ELF / PE / Mach-O architecture before committing to cache.
      validateBinaryArchitectureOrThrow(
        file: tmpUnpacked,
        targetOS: codeConfig.targetOS,
        targetArch: codeConfig.targetArchitecture,
        sourceDescription: 'downloaded prebuilt $archiveName',
      );

      if (cachedLib.existsSync()) {
        cachedLib.deleteSync();
      }
      await tmpUnpacked.rename(cachedLib.path);

      // Mark cache entry complete only after SHA-256 + binary header checks pass.
      completeMarker.writeAsStringSync('$expectedSha256\n$baseUrl\n');
      await cachedLib.copy(destination.path);
    } finally {
      for (final tmp in [tmpArchive, tmpUnpacked]) {
        if (tmp.existsSync()) {
          try {
            tmp.deleteSync();
          } catch (_) {}
        }
      }
    }
  });
}

Future<String> _resolveExpectedSha256(
  String baseUrl,
  String archiveName,
  String version,
) async {
  final embedded = _embeddedReleaseHashes[archiveName];
  if (embedded != null && embedded.length == 64) {
    return embedded.toLowerCase();
  }

  // Fallback: fetch checksums.sha256 from the release.
  final checksumsUri = Uri.parse('$baseUrl/checksums.sha256');
  final tmpChecksums = File(
    p.join(
      Directory.systemTemp.path,
      'map_checksums_${version.hashCode}_$pid.sha256',
    ),
  );
  try {
    await _downloadWithRetry(checksumsUri, tmpChecksums);
    final content = await tmpChecksums.readAsString();
    for (final line in const LineSplitter().convert(content)) {
      final match = RegExp(
        r'^([a-fA-F0-9]{64})\s+\*?(.+)$',
      ).firstMatch(line.trim());
      if (match != null && match.group(2)!.trim() == archiveName) {
        return match.group(1)!.toLowerCase();
      }
    }
    // Missing entry in remote checksums falls back cleanly to local build via InfraError.
    throw InfraError(
      message:
          'checksums.sha256 at $checksumsUri has no entry for $archiveName.',
    );
  } finally {
    if (tmpChecksums.existsSync()) {
      try {
        tmpChecksums.deleteSync();
      } catch (_) {}
    }
  }
}

Future<void> _downloadWithRetry(Uri url, File destination) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..findProxy = HttpClient.findProxyFromEnvironment;
  Object? lastError;
  final totalAttempts = _retryDelays.length + 1;

  try {
    for (var attempt = 1; attempt <= totalAttempts; attempt++) {
      try {
        final request = await client.getUrl(url);
        final response = await request.close();

        if (response.statusCode == HttpStatus.ok) {
          final sink = destination.openWrite();
          try {
            await response.pipe(sink);
          } finally {
            await sink.close();
          }
          return;
        }

        await response.drain<void>();
        if (response.statusCode == HttpStatus.notFound) {
          throw InfraError(
            message: 'Release artifact not found at $url (HTTP 404).',
          );
        }
        if (response.statusCode >= 500 ||
            response.statusCode == HttpStatus.tooManyRequests) {
          throw HttpException(
            'Transient HTTP ${response.statusCode}',
            uri: url,
          );
        }
        throw InfraError(
          message: 'Unexpected HTTP ${response.statusCode} from $url.',
        );
      } on InfraError {
        rethrow;
      } catch (e) {
        lastError = e;
        if (attempt < totalAttempts) {
          await Future<void>.delayed(_retryDelays[attempt - 1]);
        }
      }
    }
  } finally {
    client.close();
  }

  throw InfraError(
    message: 'Failed to download $url after $totalAttempts attempts: $lastError',
  );
}

Future<void> _verifyFileSha256(
  File file,
  String expectedHex,
  String displayName,
) async {
  final digest = await sha256.bind(file.openRead()).first;
  final actualHex = digest.toString().toLowerCase();
  if (actualHex != expectedHex.toLowerCase()) {
    try {
      file.deleteSync();
    } catch (_) {}
    throw BuildError(
      message: 'CRITICAL: SHA-256 checksum mismatch for $displayName!\n'
          '  Expected: $expectedHex\n'
          '  Actual:   $actualHex\n'
          'The downloaded file has been deleted to protect build integrity.',
    );
  }
}

// =============================================================================
// Local Rust + C11 Source Compilation (`cargo build`)
// =============================================================================

Future<void> _buildFromRustSource({
  required BuildInput input,
  required BuildOutputBuilder output,
  required String rustTriple,
  required String libFileName,
  required File destination,
}) async {
  final codeConfig = input.config.code;
  final rustRoot = input.packageRoot.resolve('rust/');
  final manifestFile = File.fromUri(rustRoot.resolve('Cargo.toml'));
  if (!manifestFile.existsSync()) {
    throw BuildError(
      message: 'Cannot build from source: ${manifestFile.path} not found.',
    );
  }

  final cargoTargetDir = _resolveCargoTargetDirectory(input, rustRoot);
  await cargoTargetDir.create(recursive: true);

  final lockFile = File.fromUri(
    input.outputDirectoryShared.resolve('.lock_cargo_$rustTriple'),
  );

  await _withExclusiveLock(lockFile, () async {
    final crateHash = _computeCrateHash(
      rustRoot: rustRoot,
      rustTriple: rustTriple,
      codeConfig: codeConfig,
      inputJson: input.json,
    );

    final builtLibPath = p.join(
      cargoTargetDir.path,
      rustTriple,
      'release',
      libFileName,
    );
    final builtLibFile = File(builtLibPath);
    final stampFile = File(
      p.join(cargoTargetDir.path, rustTriple, 'release', _crateHashMarker),
    );

    // Fast path: reuse compiled binary if CrateHash and binary architecture match.
    if (builtLibFile.existsSync() &&
        stampFile.existsSync() &&
        stampFile.readAsStringSync().trim() == crateHash) {
      try {
        validateBinaryArchitectureOrThrow(
          file: builtLibFile,
          targetOS: codeConfig.targetOS,
          targetArch: codeConfig.targetArchitecture,
          sourceDescription: 'cached Cargo output ($rustTriple)',
        );
        await builtLibFile.copy(destination.path);
        registerSourceDependencies(
          rustRoot: rustRoot,
          cargoTargetDir: cargoTargetDir.path,
          builtLibPath: builtLibPath,
          output: output,
        );
        return;
      } catch (_) {
        try {
          stampFile.deleteSync();
        } catch (_) {}
      }
    }

    final cargoExe = findExecutable('cargo');
    if (cargoExe == null) {
      throw BuildError(
        message: 'Rust compiler (`cargo`) not found in PATH or ~/.cargo/bin. '
            'Install Rust via https://rustup.rs to build from source.',
      );
    }

    await ensureRustTargetInstalled(rustTriple);

    final env = buildCargoEnvironment(
      codeConfig: codeConfig,
      inputJson: input.json,
      rustTriple: rustTriple,
      cargoExe: cargoExe,
      cargoTargetDir: cargoTargetDir.path,
    );

    final result = await Process.run(
      cargoExe,
      [
        'build',
        '--manifest-path',
        manifestFile.path,
        '--release',
        '--target',
        rustTriple,
        '--target-dir',
        cargoTargetDir.path,
      ],
      workingDirectory: Directory.fromUri(rustRoot).path,
      environment: env,
    );

    if (result.exitCode != 0) {
      throw BuildError(
        message:
            'Cargo build failed for target $rustTriple (exit ${result.exitCode}):\n'
            '${result.stderr}\n${result.stdout}',
      );
    }

    if (!builtLibFile.existsSync()) {
      throw BuildError(
        message:
            'Cargo succeeded, but expected output was not found at $builtLibPath',
      );
    }

    validateBinaryArchitectureOrThrow(
      file: builtLibFile,
      targetOS: codeConfig.targetOS,
      targetArch: codeConfig.targetArchitecture,
      sourceDescription: 'Cargo release build ($rustTriple)',
    );

    stampFile.writeAsStringSync('$crateHash\n');
    await builtLibFile.copy(destination.path);

    registerSourceDependencies(
      rustRoot: rustRoot,
      cargoTargetDir: cargoTargetDir.path,
      builtLibPath: builtLibPath,
      output: output,
    );
  });
}

Directory _resolveCargoTargetDirectory(BuildInput input, Uri rustRoot) {
  final userTargetDir = Platform.environment['CARGO_TARGET_DIR'];
  if (userTargetDir != null && userTargetDir.trim().isNotEmpty) {
    return Directory(p.absolute(userTargetDir.trim()));
  }
  if (Platform.isWindows) {
    // Keep paths under Windows 260-char MAX_PATH limit in cc / CMake scratch dirs.
    final rootHash = sha256
        .convert(utf8.encode(rustRoot.toFilePath()))
        .toString()
        .substring(0, 10);
    return Directory(
      p.join(Directory.systemTemp.path, 'map_cargo_$rootHash'),
    );
  }
  return Directory.fromUri(
    input.outputDirectoryShared.resolve('cargo_target/'),
  );
}

String _computeCrateHash({
  required Uri rustRoot,
  required String rustTriple,
  required CodeConfig codeConfig,
  required Map<String, Object?> inputJson,
}) {
  final filesToHash = <File>[];
  for (final rel in [
    'Cargo.toml',
    'Cargo.lock',
    'build.rs',
    '.cargo/config.toml',
  ]) {
    final f = File.fromUri(rustRoot.resolve(rel));
    if (f.existsSync()) filesToHash.add(f);
  }
  for (final sub in ['src', 'c_src']) {
    final dir = Directory.fromUri(rustRoot.resolve('$sub/'));
    if (dir.existsSync()) {
      final entries =
          dir.listSync(recursive: true).whereType<File>().where((f) {
        final ext = p.extension(f.path);
        return ext == '.rs' || ext == '.c' || ext == '.h';
      }).toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      filesToHash.addAll(entries);
    }
  }

  final dimensionKey = StringBuffer()
    ..write('triple=$rustTriple;')
    ..write('cc=${codeConfig.cCompiler?.compiler.toFilePath() ?? ''};');
  if (codeConfig.targetOS == OS.android) {
    dimensionKey.write('ndkApi=${codeConfig.android.targetNdkApi};');
  } else if (codeConfig.targetOS == OS.iOS) {
    final iosSdkLabel = codeConfig.iOS.targetSdk == IOSSdk.iPhoneSimulator
        ? 'iphonesimulator'
        : 'iphoneos';
    dimensionKey
      ..write('iosSdk=$iosSdkLabel;')
      ..write('iosVer=${resolveAppleDeploymentTarget(inputJson, OS.iOS)};');
  } else if (codeConfig.targetOS == OS.macOS) {
    dimensionKey.write(
      'macVer=${resolveAppleDeploymentTarget(inputJson, OS.macOS)};',
    );
  }

  final digests = <int>[...utf8.encode(dimensionKey.toString())];
  final rootPath = rustRoot.toFilePath();
  for (final file in filesToHash) {
    final relPosix = p.posix.joinAll(
      p.split(p.relative(file.path, from: rootPath)),
    );
    digests.addAll(utf8.encode(relPosix));
    digests.addAll(sha256.convert(file.readAsBytesSync()).bytes);
  }
  return sha256.convert(digests).toString();
}
