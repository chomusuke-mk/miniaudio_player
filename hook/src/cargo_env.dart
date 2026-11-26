import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

import 'target_triple.dart';

/// Finds an executable in `PATH`, `~/.cargo/bin`, or standard macOS Homebrew dirs.
String? findExecutable(String name) {
  final exeName = Platform.isWindows ? '$name.exe' : name;
  final pathSep = Platform.isWindows ? ';' : ':';
  final pathEnv = _readEnvCaseInsensitive(Platform.environment, 'PATH') ?? '';

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

/// Ensures [rustTriple] is installed via `rustup target add` if `rustup` exists.
Future<void> ensureRustTargetInstalled(String rustTriple) async {
  final rustupExe = findExecutable('rustup');
  if (rustupExe == null) return;

  final listRes = await Process.run(
    rustupExe,
    ['target', 'list', '--installed'],
  );
  if (listRes.exitCode != 0) {
    throw BuildError(
      message: 'Failed to query installed Rust targets via `rustup`: '
          '${listRes.stderr}',
    );
  }

  final installed = (listRes.stdout as String)
      .split('\n')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet();
  if (!installed.contains(rustTriple)) {
    final addRes = await Process.run(
      rustupExe,
      ['target', 'add', rustTriple],
    );
    if (addRes.exitCode != 0) {
      throw BuildError(
        message: 'Failed to install Rust target `$rustTriple` via `rustup target add`: '
            '${addRes.stderr}\n${addRes.stdout}',
      );
    }
  }
}

/// Builds a sanitized cross-compilation environment for `cargo build`.
Map<String, String> buildCargoEnvironment({
  required CodeConfig codeConfig,
  required Map<String, Object?> inputJson,
  required String rustTriple,
  required String cargoExe,
  required String cargoTargetDir,
}) {
  final env = Map<String, String>.from(Platform.environment);
  final targetOS = codeConfig.targetOS;
  final pathSep = Platform.isWindows ? ';' : ':';

  // Ensure cargo's bin directory is present so rustc/rustup shims resolve.
  final cargoBinDir = p.dirname(cargoExe);
  var currentPath = _readEnvCaseInsensitive(env, 'PATH') ?? '';
  if (!currentPath.split(pathSep).contains(cargoBinDir)) {
    currentPath =
        currentPath.isEmpty ? cargoBinDir : '$cargoBinDir$pathSep$currentPath';
  }

  // On macOS hosts, filter out Xcode's `.../Contents/Developer/...` entries so
  // host `build.rs` compilation picks up the host toolchain cleanly without
  // breaking user directories like `~/Developer/`.
  if (Platform.isMacOS) {
    currentPath = currentPath
        .split(':')
        .where((e) => !e.contains('Contents/Developer/'))
        .join(':');
  }
  _putEnv(env, 'PATH', currentPath);

  if (targetOS == OS.iOS || targetOS == OS.macOS) {
    _configureAppleEnv(
      env: env,
      codeConfig: codeConfig,
      inputJson: inputJson,
      rustTriple: rustTriple,
    );
  } else if (targetOS == OS.android) {
    _configureAndroidNdkEnv(
      env: env,
      codeConfig: codeConfig,
      rustTriple: rustTriple,
      cargoTargetDir: cargoTargetDir,
    );
  } else if (targetOS == OS.linux) {
    _configureLinuxEnv(
      env: env,
      codeConfig: codeConfig,
      rustTriple: rustTriple,
    );
  } else if (targetOS == OS.windows) {
    _configureWindowsEnv(
      env: env,
      codeConfig: codeConfig,
    );
  }

  return env;
}

void _configureAppleEnv({
  required Map<String, String> env,
  required CodeConfig codeConfig,
  required Map<String, Object?> inputJson,
  required String rustTriple,
}) {
  // Scrub global Xcode env vars injected by IDE build phases so host build.rs
  // scripts compile against the macOS SDK while target builds use xcrun/cc.
  for (final key in [
    'SDKROOT',
    'PLATFORM_NAME',
    'ARCHS',
    'SUPPORTED_PLATFORMS',
    'EFFECTIVE_PLATFORM_NAME',
    'IPHONEOS_DEPLOYMENT_TARGET',
    'MACOSX_DEPLOYMENT_TARGET',
    'CC',
    'CXX',
    'CFLAGS',
    'CXXFLAGS',
    'LDFLAGS',
    'LIBRARY_PATH',
    'CPATH',
  ]) {
    env.remove(key);
  }

  final deploymentTarget =
      resolveAppleDeploymentTarget(inputJson, codeConfig.targetOS);
  if (codeConfig.targetOS == OS.iOS) {
    env['IPHONEOS_DEPLOYMENT_TARGET'] = deploymentTarget;
  } else {
    env['MACOSX_DEPLOYMENT_TARGET'] = deploymentTarget;
  }

  final cCompiler = codeConfig.cCompiler;
  if (cCompiler != null) {
    final tripleUnder = rustTriple.replaceAll('-', '_');
    final tripleUpper = tripleUnder.toUpperCase();
    final compilerPath = cCompiler.compiler.toFilePath();
    final archiverPath = cCompiler.archiver.toFilePath();
    env['CC_$tripleUnder'] = compilerPath;
    env['AR_$tripleUnder'] = archiverPath;
    env['CARGO_TARGET_${tripleUpper}_LINKER'] = compilerPath;
  }
}

void _configureAndroidNdkEnv({
  required Map<String, String> env,
  required CodeConfig codeConfig,
  required String rustTriple,
  required String cargoTargetDir,
}) {
  final cCompiler = codeConfig.cCompiler;
  if (cCompiler == null) {
    throw BuildError(
      message:
          'Android source build requires CodeConfig.cCompiler (Android NDK) for $rustTriple.',
    );
  }

  final clangPath = cCompiler.compiler.toFilePath();
  final arPath = cCompiler.archiver.toFilePath();
  final binDir = p.dirname(clangPath);
  final sysrootDir = p.normalize(p.join(binDir, '..', 'sysroot'));
  final api = codeConfig.android.targetNdkApi;

  // Clang target triple differs from Rust triple on 32-bit ARM.
  final ndkClangTriple = rustTriple == 'armv7-linux-androideabi'
      ? 'armv7a-linux-androideabi'
      : rustTriple;
  final ndkSysrootTriple = rustTriple == 'armv7-linux-androideabi'
      ? 'arm-linux-androideabi'
      : rustTriple;
  final targetFlag = '--target=$ndkClangTriple$api';

  final tripleUnder = rustTriple.replaceAll('-', '_');
  final tripleUpper = tripleUnder.toUpperCase();

  // Configure `cc` crate with shell-escaped flags so spaces in NDK/SDK paths work cleanly.
  env['CC_$tripleUnder'] = clangPath;
  env['AR_$tripleUnder'] = arPath;
  env['CC_SHELL_ESCAPED_FLAGS'] = '1';
  env['CFLAGS_$tripleUnder'] =
      '$targetFlag ${_quotePosixShellArg('--sysroot=$sysrootDir')} '
      '-D__ANDROID_API__=$api -fPIC';

  final ranlibName = Platform.isWindows ? 'llvm-ranlib.exe' : 'llvm-ranlib';
  final ranlibFile = File(p.join(binDir, ranlibName));
  if (ranlibFile.existsSync()) {
    env['RANLIB_$tripleUnder'] = ranlibFile.path;
  }

  final sysrootForward = sysrootDir.replaceAll(r'\', '/');
  env['BINDGEN_EXTRA_CLANG_ARGS_$tripleUnder'] =
      '--sysroot=$sysrootForward -I$sysrootForward/usr/include/$ndkSysrootTriple';

  // Create NDK r23+ libgcc -> libunwind compatibility linker script.
  final libgccDir = Directory(p.join(cargoTargetDir, 'ndk_libgcc_stub'));
  libgccDir.createSync(recursive: true);
  File(
    p.join(libgccDir.path, 'libgcc.a'),
  ).writeAsStringSync('INPUT(-lunwind)\n');

  // Invoke clang(.exe) directly as linker (avoiding Windows .cmd quoting issues)
  // and pass CARGO_ENCODED_RUSTFLAGS (\x1f-separated) so paths with spaces never break.
  env['CARGO_TARGET_${tripleUpper}_LINKER'] = clangPath;
  env.remove('RUSTFLAGS');
  env.remove('CARGO_TARGET_${tripleUpper}_RUSTFLAGS');
  env['CARGO_ENCODED_RUSTFLAGS'] = <String>[
    '-C',
    'link-arg=$targetFlag',
    '-C',
    'link-arg=--sysroot=$sysrootDir',
    '-C',
    'link-arg=-Wl,-z,max-page-size=16384',
    '-L',
    libgccDir.path,
  ].join('\u001f');
}

void _configureLinuxEnv({
  required Map<String, String> env,
  required CodeConfig codeConfig,
  required String rustTriple,
}) {
  final tripleUnder = rustTriple.replaceAll('-', '_');
  final tripleUpper = tripleUnder.toUpperCase();
  final cCompiler = codeConfig.cCompiler;

  if (codeConfig.targetArchitecture == Architecture.current &&
      cCompiler != null) {
    // Use the exact C compiler driver (NOT cCompiler.linker, which Flutter sets
    // to raw `ld` from CMakeCache.txt and cannot be invoked directly by rustc).
    final compilerPath = cCompiler.compiler.toFilePath();
    final archiverPath = cCompiler.archiver.toFilePath();
    env['CC_$tripleUnder'] = compilerPath;
    env['AR_$tripleUnder'] = archiverPath;
    env['CARGO_TARGET_${tripleUpper}_LINKER'] = compilerPath;
    return;
  }

  // Cross-compilation fallback on Linux host.
  if (codeConfig.targetArchitecture == Architecture.arm64) {
    final crossCc = findExecutable('aarch64-linux-gnu-gcc');
    if (crossCc != null) {
      env['CC_$tripleUnder'] = crossCc;
      env['CARGO_TARGET_${tripleUpper}_LINKER'] = crossCc;
      final crossAr = findExecutable('aarch64-linux-gnu-ar');
      if (crossAr != null) env['AR_$tripleUnder'] = crossAr;
    }
  } else if (codeConfig.targetArchitecture == Architecture.ia32) {
    final crossCc = findExecutable('i686-linux-gnu-gcc');
    if (crossCc != null) {
      env['CC_$tripleUnder'] = crossCc;
      env['CARGO_TARGET_${tripleUpper}_LINKER'] = crossCc;
      final crossAr = findExecutable('i686-linux-gnu-ar');
      if (crossAr != null) env['AR_$tripleUnder'] = crossAr;
    } else if (cCompiler != null && Architecture.current == Architecture.x64) {
      final compilerPath = cCompiler.compiler.toFilePath();
      env['CC_$tripleUnder'] = compilerPath;
      env['CFLAGS_$tripleUnder'] = '-m32';
      env['CARGO_TARGET_${tripleUpper}_LINKER'] = compilerPath;
      env['CARGO_ENCODED_RUSTFLAGS'] = '-C\u001flink-arg=-m32';
    }
  }
}

void _configureWindowsEnv({
  required Map<String, String> env,
  required CodeConfig codeConfig,
}) {
  if (!Platform.isWindows) return;
  final devCmd = codeConfig.cCompiler?.windows.developerCommandPrompt;
  if (devCmd == null) return;

  final scriptFile = File.fromUri(devCmd.script);
  if (!scriptFile.existsSync()) return;

  var scriptPath = scriptFile.path;
  var args = List<String>.from(devCmd.arguments);

  // If Flutter gave `vcvars64.bat` (or `vcvarsarm64.bat` / `vcvars32.bat`) for
  // the host while cross-compiling to another arch, switch to `vcvarsall.bat`.
  final scriptName = p.basename(scriptPath).toLowerCase();
  final targetArch = codeConfig.targetArchitecture;
  if (scriptName != 'vcvarsall.bat' &&
      targetArch != Architecture.current &&
      args.isEmpty) {
    final vcvarsAll = File(p.join(p.dirname(scriptPath), 'vcvarsall.bat'));
    if (vcvarsAll.existsSync()) {
      scriptPath = vcvarsAll.path;
      args = _resolveVcvarsArchArgs(Architecture.current, targetArch);
    }
  } else if (scriptName == 'vcvarsall.bat' && args.isEmpty) {
    args = _resolveVcvarsArchArgs(Architecture.current, targetArch);
  }

  final batchEnv = extractBatchEnvironment(
    scriptPath: scriptPath,
    args: args,
    baseEnvironment: env,
  );
  for (final entry in batchEnv.entries) {
    _putEnv(env, entry.key, entry.value);
  }
}

const _vcvarsEnvMarker = '__MINIAUDIO_VCVARS_ENV_START__';

/// Runs a Windows batch script (such as `vcvars64.bat` or `vcvarsall.bat`) via
/// a temporary wrapper `.cmd` file and returns the resulting environment map.
///
/// Writing a temporary wrapper avoids `dart:io`'s Win32 `\"` quoting rules
/// corrupting paths with spaces inside `cmd.exe /c`, and preserves any prior
/// modifications present in [baseEnvironment].
Map<String, String> extractBatchEnvironment({
  required String scriptPath,
  List<String> args = const [],
  Map<String, String>? baseEnvironment,
}) {
  final envForChild = Map<String, String>.from(
    baseEnvironment ?? Platform.environment,
  );
  final tmpDir = Directory.systemTemp.createTempSync('map_vcvars_');
  try {
    final escapedScript = _escapeBatchText(scriptPath);
    final formattedArgs = args.map(_formatBatchArg).join(' ');
    final argSuffix = formattedArgs.isEmpty ? '' : ' $formattedArgs';
    final wrapperContent = StringBuffer()
      ..writeln('@echo off')
      ..writeln('call "$escapedScript"$argSuffix')
      ..writeln('if errorlevel 1 exit /b %errorlevel%')
      ..writeln('@echo $_vcvarsEnvMarker')
      ..writeln('@set');

    final wrapperFile = File(p.join(tmpDir.path, 'run_vcvars.cmd'));
    wrapperFile.writeAsStringSync(
      wrapperContent.toString(),
      encoding: systemEncoding,
    );

    final comspec = _readEnvCaseInsensitive(envForChild, 'COMSPEC') ??
        _readEnvCaseInsensitive(Platform.environment, 'COMSPEC') ??
        'cmd.exe';
    final cmdRes = Process.runSync(
      comspec,
      ['/d', '/c', r'.\run_vcvars.cmd'],
      workingDirectory: tmpDir.path,
      environment: envForChild,
    );

    final stdoutStr = (cmdRes.stdout ?? '').toString();
    final stderrStr = (cmdRes.stderr ?? '').toString();
    if (cmdRes.exitCode != 0) {
      final argDesc = args.isEmpty ? '' : ' ${args.join(' ')}';
      final details = [stderrStr.trim(), stdoutStr.trim()]
          .where((s) => s.isNotEmpty)
          .join('\n');
      throw BuildError(
        message: 'Failed to initialize MSVC Developer Command Prompt '
            '("$scriptPath"$argDesc, exit ${cmdRes.exitCode}): $details',
      );
    }

    final lines = const LineSplitter().convert(stdoutStr);
    final markerIdx = lines.lastIndexWhere(
      (line) => line.trim() == _vcvarsEnvMarker,
    );
    if (markerIdx == -1) {
      throw BuildError(
        message: 'Failed to parse MSVC Developer Command Prompt output for '
            '"$scriptPath": missing environment marker.',
      );
    }

    final parsed = <String, String>{};
    for (var i = markerIdx + 1; i < lines.length; i++) {
      final line = lines[i];
      final eqIdx = line.indexOf('=');
      if (eqIdx <= 0) continue;
      final key = line.substring(0, eqIdx);
      final val = line.substring(eqIdx + 1);
      _putEnv(parsed, key, val);
    }
    return parsed;
  } finally {
    try {
      tmpDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

String _escapeBatchText(String value) => value.replaceAll('%', '%%');

String _formatBatchArg(String arg) {
  final escaped = _escapeBatchText(arg);
  if (escaped.isEmpty ||
      escaped.contains(' ') ||
      escaped.contains('\t') ||
      escaped.contains('&') ||
      escaped.contains('(') ||
      escaped.contains(')')) {
    return '"$escaped"';
  }
  return escaped;
}

List<String> _resolveVcvarsArchArgs(Architecture host, Architecture target) {
  String vcvarsToken(Architecture arch, {required bool isHost}) =>
      switch (arch) {
        Architecture.x64 => isHost ? 'amd64' : 'x64',
        Architecture.arm64 => 'arm64',
        Architecture.ia32 => 'x86',
        _ => 'amd64',
      };
  if (host == target) {
    return [vcvarsToken(target, isHost: false)];
  }
  final hostTok = vcvarsToken(host, isHost: true);
  final targetTok =
      target == Architecture.x64 ? 'amd64' : vcvarsToken(target, isHost: false);
  return ['${hostTok}_$targetTok'];
}

String _quotePosixShellArg(String value) {
  return "'${value.replaceAll("'", r"'\''")}'";
}

String? _readEnvCaseInsensitive(Map<String, String> env, String key) {
  if (!Platform.isWindows) return env[key];
  final target = key.toLowerCase();
  for (final entry in env.entries) {
    if (entry.key.toLowerCase() == target) return entry.value;
  }
  return null;
}

void _putEnv(Map<String, String> env, String key, String value) {
  if (Platform.isWindows) {
    final target = key.toLowerCase();
    env.removeWhere((k, _) => k.toLowerCase() == target);
  }
  env[key] = value;
}
