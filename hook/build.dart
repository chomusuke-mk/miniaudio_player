import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

const _packageName = 'miniaudio_player';
const _defaultVersion = '3.0.2';
const _githubRepo = 'chomusuke-mk/miniaudio_player';
const _cacheCompleteMarker = '.download-complete';
const _crateHashMarker = '.crate-hash';

/// Embedded SHA-256 checksums for official GitHub Release archives.
///
/// Populated automatically by `tool/update_release_hashes.dart` during the CI
/// release workflow before `dart pub publish`. When an entry is present here,
/// the hook verifies the downloaded archive against this immutable compile-time
/// hash; otherwise it fetches and verifies `checksums.sha256` from the release.
const Map<String, String> _embeddedReleaseHashes = <String, String>{
  // 'miniaudio_player-v3.0.2-aarch64-linux-android.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-armv7-linux-androideabi.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-x86_64-linux-android.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-aarch64-apple-ios.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-aarch64-apple-ios-sim.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-x86_64-apple-ios.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-aarch64-apple-darwin.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-x86_64-apple-darwin.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-x86_64-unknown-linux-gnu.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-aarch64-unknown-linux-gnu.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-x86_64-pc-windows-msvc.tar.gz': '<sha256>',
  // 'miniaudio_player-v3.0.2-aarch64-pc-windows-msvc.tar.gz': '<sha256>',
};

const _retryDelays = <Duration>[
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];

void main(List<String> args) async {
  await build(args, (input, output) async {
    // Always track hook/build.dart and pubspec.yaml as baseline dependencies.
    output.dependencies.add(input.packageRoot.resolve('hook/build.dart'));
    output.dependencies.add(input.packageRoot.resolve('pubspec.yaml'));

    // Provision web/pkg/ for web consumers if a `web/` directory exists in the workspace.
    _provisionWebAssetsIfNeeded(input);

    if (!input.config.buildCodeAssets) {
      return;
    }

    final version = _resolvePackageVersion(input);
    final codeConfig = input.config.code;
    final targetOS = codeConfig.targetOS;
    final targetArch = codeConfig.targetArchitecture;
    final iosSdk = targetOS == OS.iOS ? codeConfig.iOS.targetSdk : null;

    final rustTriple = _resolveRustTriple(targetOS, targetArch, iosSdk);
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
    // Priority 4: Prebuilt Binary Download from GitHub Releases (Default)
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
      // Security / checksum mismatch errors must NEVER fall back silently.
      rethrow;
    } catch (downloadErr) {
      // -----------------------------------------------------------------------
      // Priority 5: Automatic Fallback to Local Cargo Build if Rust is present
      // -----------------------------------------------------------------------
      final rustDir = Directory.fromUri(input.packageRoot.resolve('rust/'));
      final cargoExe = _findExecutable('cargo');
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
            '  2. Provide a local binary via MINIAUDIO_PLAYER_LIB_PATH=/path/to/$libFileName, OR\n'
            '  3. Install Rust (https://rustup.rs) and set MINIAUDIO_PLAYER_BUILD_FROM_SOURCE=1.',
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

// =============================================================================
// Prebuilt Binary Download, Atomic Caching & SHA-256 Verification
// =============================================================================

Future<void> _acquirePrebuiltBinary({
  required BuildInput input,
  required String version,
  required String rustTriple,
  required String libFileName,
  required File destination,
}) async {
  final archiveName = '$_packageName-v$version-$rustTriple.tar.gz';
  final baseUrl = _resolveDownloadBaseUrl(input, version);
  final downloadUrl = '$baseUrl/$archiveName';

  final cacheDir = Directory.fromUri(
    input.outputDirectoryShared.resolve('prebuilt-v$version-$rustTriple/'),
  );
  final cachedLib = File(p.join(cacheDir.path, libFileName));
  final completeMarker = File(p.join(cacheDir.path, _cacheCompleteMarker));

  // Fast path: reuse verified shared cache entry.
  if (completeMarker.existsSync() && cachedLib.existsSync()) {
    await cachedLib.copy(destination.path);
    return;
  }

  await cacheDir.create(recursive: true);
  final expectedSha256 = await _resolveExpectedSha256(
    baseUrl,
    archiveName,
    version,
  );

  final tmpArchive = File(p.join(cacheDir.path, '$archiveName.tmp.$pid'));
  try {
    await _downloadWithRetry(Uri.parse(downloadUrl), tmpArchive);
    await _verifyFileSha256(tmpArchive, expectedSha256, archiveName);

    // Extract tar.gz into cacheDir
    final extractRes = await Process.run('tar', [
      '-xzf',
      tmpArchive.path,
      '-C',
      cacheDir.path,
    ]);
    if (extractRes.exitCode != 0) {
      throw InfraError(
        message: 'Failed to extract $archiveName: ${extractRes.stderr}',
      );
    }

    if (!cachedLib.existsSync()) {
      throw BuildError(
        message:
            'Archive $archiveName did not contain expected binary $libFileName.',
      );
    }

    // Mark cache entry complete only after verified extraction.
    completeMarker.writeAsStringSync('$expectedSha256\n');
    await cachedLib.copy(destination.path);
  } finally {
    if (tmpArchive.existsSync()) {
      try {
        tmpArchive.deleteSync();
      } catch (_) {}
    }
  }
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
    throw BuildError(
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
          throw HttpException('Transient HTTP ${response.statusCode}',
              uri: url);
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
    message:
        'Failed to download $url after $totalAttempts attempts: $lastError',
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
// Local Rust + C99 Source Compilation (`cargo build`)
// =============================================================================

Future<void> _buildFromRustSource({
  required BuildInput input,
  required BuildOutputBuilder output,
  required String rustTriple,
  required String libFileName,
  required File destination,
}) async {
  final rustRoot = input.packageRoot.resolve('rust/');
  final manifestFile = File.fromUri(rustRoot.resolve('Cargo.toml'));
  if (!manifestFile.existsSync()) {
    throw BuildError(
      message: 'Cannot build from source: ${manifestFile.path} not found.',
    );
  }

  // Compute deterministic CrateHash over Cargo.toml, Cargo.lock, build.rs,
  // rust/src/**/*.rs, and rust/c_src/**/*.{c,h}.
  final crateHash = _computeCrateHash(rustRoot);

  // On Windows, deep paths under .dart_tool/hooks_runner/shared/... exceed the
  // 260-character MAX_PATH limit inside cc/audiopus_sys build directories.
  // Use a short deterministic directory in systemTemp on Windows.
  final Directory cargoTargetDir;
  if (Platform.isWindows) {
    final rootHash = sha256
        .convert(utf8.encode(rustRoot.toFilePath()))
        .toString()
        .substring(0, 10);
    cargoTargetDir = Directory(
      p.join(Directory.systemTemp.path, 'map_cargo_$rootHash'),
    );
  } else {
    cargoTargetDir = Directory.fromUri(
      input.outputDirectoryShared.resolve('cargo_target/'),
    );
  }
  await cargoTargetDir.create(recursive: true);

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

  // Fast path: if the binary already exists for this exact CrateHash, skip invoking cargo!
  if (builtLibFile.existsSync() &&
      stampFile.existsSync() &&
      stampFile.readAsStringSync().trim() == crateHash) {
    await builtLibFile.copy(destination.path);
    _registerSourceDependencies(
      rustRoot: rustRoot,
      cargoTargetDir: cargoTargetDir.path,
      builtLibPath: builtLibPath,
      output: output,
    );
    return;
  }

  final cargoExe = _findExecutable('cargo');
  if (cargoExe == null) {
    throw BuildError(
      message: 'Rust compiler (`cargo`) not found in PATH or ~/.cargo/bin. '
          'Install Rust via https://rustup.rs to build from source.',
    );
  }

  await _ensureRustTargetInstalled(rustTriple);

  final env = _buildCargoEnvironment(
    input: input,
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

  stampFile.writeAsStringSync('$crateHash\n');
  await builtLibFile.copy(destination.path);

  _registerSourceDependencies(
    rustRoot: rustRoot,
    cargoTargetDir: cargoTargetDir.path,
    builtLibPath: builtLibPath,
    output: output,
  );
}

/// Parses Cargo's `.d` dep-info file and registers source dependencies
/// without triggering `hooks_runner` self-invalidation.
void _registerSourceDependencies({
  required Uri rustRoot,
  required String cargoTargetDir,
  required String builtLibPath,
  required BuildOutputBuilder output,
}) {
  final normalizedTargetDir = p.normalize(cargoTargetDir);
  final depFile = File(p.setExtension(builtLibPath, '.d'));

  var parsedDepFile = false;
  if (depFile.existsSync()) {
    for (final line in depFile.readAsLinesSync()) {
      // Split on the FIRST ": " (with space) to preserve Windows C:\ drive letters.
      final sepIdx = line.indexOf(': ');
      if (sepIdx == -1) continue;
      final target = line.substring(0, sepIdx).trim();
      if (p.normalize(target) != p.normalize(builtLibPath)) continue;

      final depsRaw = line.substring(sepIdx + 2).trim();
      for (final depPath in _splitMakeDeps(depsRaw)) {
        final norm = p.normalize(depPath);
        // Never add `.d` files or files inside cargoTargetDir (prevents infinite rebuild loop).
        if (p.extension(norm) == '.d' ||
            p.isWithin(normalizedTargetDir, norm)) {
          continue;
        }
        final file = File(norm);
        if (file.existsSync()) {
          output.dependencies.add(file.uri);
          parsedDepFile = true;
        }
      }
    }
  }

  // Always explicitly register Cargo.toml, build.rs, and c_src/*.{c,h}.
  for (final rel in [
    'Cargo.toml',
    'build.rs',
    'c_src/miniaudio.h',
    'c_src/miniaudio_device_bridge.h',
    'c_src/miniaudio_device_bridge.c',
  ]) {
    final f = File.fromUri(rustRoot.resolve(rel));
    if (f.existsSync()) {
      output.dependencies.add(f.uri);
    }
  }

  // Fallback if .d file wasn't found: scan rust/src/**/*.rs
  if (!parsedDepFile) {
    final srcDir = Directory.fromUri(rustRoot.resolve('src/'));
    if (srcDir.existsSync()) {
      for (final entity in srcDir.listSync(recursive: true)) {
        if (entity is File && p.extension(entity.path) == '.rs') {
          output.dependencies.add(entity.uri);
        }
      }
    }
  }
}

List<String> _splitMakeDeps(String raw) {
  final results = <String>[];
  final current = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    if (raw[i] == r'\' && i + 1 < raw.length && raw[i + 1] == ' ') {
      current.write(' ');
      i++;
    } else if (raw[i] == ' ' || raw[i] == '\t') {
      if (current.isNotEmpty) {
        results.add(current.toString());
        current.clear();
      }
    } else {
      current.write(raw[i]);
    }
  }
  if (current.isNotEmpty) {
    results.add(current.toString());
  }
  return results;
}

String _computeCrateHash(Uri rustRoot) {
  final filesToHash = <File>[];
  for (final rel in ['Cargo.toml', 'Cargo.lock', 'build.rs']) {
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

  final digests = <int>[];
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

// =============================================================================
// Toolchain Discovery & Cross-Compilation Environment Construction
// =============================================================================

String? _findExecutable(String name) {
  final exeName = Platform.isWindows ? '$name.exe' : name;
  final pathSep = Platform.isWindows ? ';' : ':';
  final pathEnv = Platform.environment['PATH'] ?? '';

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';

  final searchDirs = <String>[
    ...pathEnv.split(pathSep).where((s) => s.isNotEmpty),
    if (home.isNotEmpty) p.join(home, '.cargo', 'bin'),
    if (!Platform.isWindows) ...['/opt/homebrew/bin', '/usr/local/bin'],
  ];

  for (final dir in searchDirs) {
    final candidate = File(p.join(dir, exeName));
    if (candidate.existsSync()) {
      return candidate.path;
    }
  }
  return null;
}

Future<void> _ensureRustTargetInstalled(String rustTriple) async {
  final rustupExe = _findExecutable('rustup');
  if (rustupExe == null) return;

  final listRes = await Process.run(
    rustupExe,
    ['target', 'list', '--installed'],
  );
  if (listRes.exitCode == 0) {
    final installed =
        (listRes.stdout as String).split('\n').map((s) => s.trim()).toSet();
    if (!installed.contains(rustTriple)) {
      await Process.run(rustupExe, ['target', 'add', rustTriple]);
    }
  }
}

Map<String, String> _buildCargoEnvironment({
  required BuildInput input,
  required String rustTriple,
  required String cargoExe,
  required String cargoTargetDir,
}) {
  final env = Map<String, String>.from(Platform.environment);
  final codeConfig = input.config.code;
  final targetOS = codeConfig.targetOS;
  final pathSep = Platform.isWindows ? ';' : ':';

  // Ensure cargo's bin directory is on PATH so rustc/rustup shims resolve.
  final cargoBinDir = p.dirname(cargoExe);
  var currentPath = env['PATH'] ?? '';
  if (!currentPath.split(pathSep).contains(cargoBinDir)) {
    currentPath = '$cargoBinDir$pathSep$currentPath';
  }

  // On macOS, Xcode build phases inject Contents/Developer/... into PATH, which
  // breaks Cargo host build.rs compilation when targeting iOS.
  if (Platform.isMacOS && targetOS == OS.iOS) {
    currentPath = currentPath
        .split(':')
        .where((e) => !p.split(e).contains('Developer'))
        .join(':');
  }
  env['PATH'] = currentPath;

  if (targetOS == OS.iOS) {
    // ignore: deprecated_member_use
    env['IPHONEOS_DEPLOYMENT_TARGET'] = '${codeConfig.iOS.targetVersion}';
  } else if (targetOS == OS.macOS) {
    // ignore: deprecated_member_use
    env['MACOSX_DEPLOYMENT_TARGET'] = '${codeConfig.macOS.targetVersion}';
  } else if (targetOS == OS.android) {
    _configureAndroidNdkEnv(
      env: env,
      codeConfig: codeConfig,
      rustTriple: rustTriple,
      cargoTargetDir: cargoTargetDir,
    );
  }

  return env;
}

void _configureAndroidNdkEnv({
  required Map<String, String> env,
  required CodeConfig codeConfig,
  required String rustTriple,
  required String cargoTargetDir,
}) {
  final cCompiler = codeConfig.cCompiler;
  if (cCompiler == null) return;

  final clangPath = cCompiler.compiler.toFilePath();
  final arPath = cCompiler.archiver.toFilePath();
  final binDir = p.dirname(clangPath);
  final sysrootDir = p.normalize(p.join(binDir, '..', 'sysroot'));
  final api = codeConfig.android.targetNdkApi;

  // For 32-bit ARM, Rust's triple is armv7-linux-androideabi, but Clang's
  // target flag requires armv7a-linux-androideabi<api>.
  final ndkClangTriple = rustTriple == 'armv7-linux-androideabi'
      ? 'armv7a-linux-androideabi'
      : rustTriple;
  final targetFlag = '--target=$ndkClangTriple$api';

  final tripleUnder = rustTriple.replaceAll('-', '_');
  final tripleUpper = tripleUnder.toUpperCase();

  // Configure `cc` crate (for miniaudio_device_bridge.c and audiopus_sys)
  env['CC_$tripleUnder'] = clangPath;
  env['AR_$tripleUnder'] = arPath;
  env['CFLAGS_$tripleUnder'] =
      '$targetFlag --sysroot=$sysrootDir -D__ANDROID_API__=$api -fPIC';

  final ranlibName = Platform.isWindows ? 'llvm-ranlib.exe' : 'llvm-ranlib';
  final ranlibFile = File(p.join(binDir, ranlibName));
  if (ranlibFile.existsSync()) {
    env['RANLIB_$tripleUnder'] = ranlibFile.path;
  }

  // Create NDK r23+ libgcc -> libunwind compatibility linker script
  final libgccDir = Directory(p.join(cargoTargetDir, 'ndk_libgcc_stub'));
  libgccDir.createSync(recursive: true);
  File(
    p.join(libgccDir.path, 'libgcc.a'),
  ).writeAsStringSync('INPUT(-lunwind)\n');

  // Invoke clang(.exe) directly as the Rust linker (bypassing Windows .cmd
  // batch wrapper escaping bugs in android/ndk#1856) and pass --target + 16KB page size.
  env['CARGO_TARGET_${tripleUpper}_LINKER'] = clangPath;
  env['CARGO_TARGET_${tripleUpper}_RUSTFLAGS'] = [
    '-C',
    'link-arg=$targetFlag',
    '-C',
    'link-arg=--sysroot=$sysrootDir',
    '-C',
    'link-arg=-Wl,-z,max-page-size=16384',
    '-L',
    libgccDir.path,
  ].join(' ');
}

String _resolveRustTriple(OS os, Architecture arch, IOSSdk? iosSdk) {
  switch (os) {
    case OS.android:
      if (arch == Architecture.arm64) return 'aarch64-linux-android';
      if (arch == Architecture.arm) return 'armv7-linux-androideabi';
      if (arch == Architecture.x64) return 'x86_64-linux-android';
      break;
    case OS.iOS:
      if (arch == Architecture.arm64) {
        return iosSdk == IOSSdk.iPhoneSimulator
            ? 'aarch64-apple-ios-sim'
            : 'aarch64-apple-ios';
      }
      if (arch == Architecture.x64) return 'x86_64-apple-ios';
      break;
    case OS.macOS:
      if (arch == Architecture.arm64) return 'aarch64-apple-darwin';
      if (arch == Architecture.x64) return 'x86_64-apple-darwin';
      break;
    case OS.linux:
      if (arch == Architecture.x64) return 'x86_64-unknown-linux-gnu';
      if (arch == Architecture.arm64) return 'aarch64-unknown-linux-gnu';
      break;
    case OS.windows:
      if (arch == Architecture.x64) return 'x86_64-pc-windows-msvc';
      if (arch == Architecture.arm64) return 'aarch64-pc-windows-msvc';
      break;
  }
  throw BuildError(message: 'Unsupported platform/architecture: $os / $arch');
}

// =============================================================================
// Web WASM Asset Provisioning
// =============================================================================

void _provisionWebAssetsIfNeeded(BuildInput input) {
  try {
    final pkgWebDir = Directory.fromUri(input.packageRoot.resolve('web/pkg/'));
    if (!pkgWebDir.existsSync()) return;

    // Locate the consuming app's root from input.outputDirectory
    // (<appRoot>/.dart_tool/hooks_runner/...)
    var dir = Directory.fromUri(input.outputDirectory);
    Directory? appRoot;
    while (dir.parent.path != dir.path) {
      if (p.basename(dir.path) == '.dart_tool') {
        appRoot = dir.parent;
        break;
      }
      dir = dir.parent;
    }
    if (appRoot == null) return;

    final consumerWebDir = Directory(p.join(appRoot.path, 'web'));
    if (!consumerWebDir.existsSync()) return;

    final destPkgDir = Directory(p.join(consumerWebDir.path, 'pkg'));
    destPkgDir.createSync(recursive: true);

    for (final fileName in [
      'miniaudio_player.js',
      'miniaudio_player_bg.wasm',
    ]) {
      final src = File(p.join(pkgWebDir.path, fileName));
      final dst = File(p.join(destPkgDir.path, fileName));
      if (src.existsSync()) {
        if (!dst.existsSync() ||
            src.lengthSync() != dst.lengthSync() ||
            src.lastModifiedSync().isAfter(dst.lastModifiedSync())) {
          src.copySync(dst.path);
        }
      }
    }
  } catch (_) {
    // Best-effort provisioning; Flutter Web also serves via `flutter: assets:`.
  }
}
