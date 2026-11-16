import 'dart:io';

import 'package:path/path.dart' as p;

const _webThreadedRustFlags =
    '-C target-feature=+atomics,+bulk-memory,+mutable-globals '
    '-C link-args=--shared-memory '
    '-C link-args=--max-memory=1073741824 '
    '-C link-args=--import-memory '
    '-C link-args=--export=__heap_base '
    '-C link-args=--export=__wasm_init_tls '
    '-C link-args=--export=__tls_size '
    '-C link-args=--export=__tls_align '
    '-C link-args=--export=__tls_base';

const _distAssetNames = <String>[
  'miniaudio_player.js',
  'miniaudio_player_bg.wasm',
];

/// Compiles the Rust audio engine to multi-threaded WebAssembly (`wasm32`)
/// into an ignored staging directory (`build/web_wasm/pkg/`) and copies only
/// the clean distribution artifacts (`miniaudio_player.js` and
/// `miniaudio_player_bg.wasm`) into `assets/web/`.
Future<void> main(List<String> args) async {
  if (args.contains('-h') || args.contains('--help')) {
    stdout.writeln('''
Usage: dart run tool/build_web_wasm.dart [--debug|--dev]

Builds the multi-threaded WebAssembly bundle into `build/web_wasm/pkg/` and
publishes only `miniaudio_player.js` and `miniaudio_player_bg.wasm` to
`assets/web/` (excluding `.gitignore`, `package.json`, and `*.d.ts`).
''');
    return;
  }

  final isDebug = args.contains('--debug') || args.contains('--dev');
  final repoRoot = _resolveRepoRoot();
  final rustDir = p.join(repoRoot, 'rust');
  final stagingDir = p.join(repoRoot, 'build', 'web_wasm', 'pkg');
  final assetsWebDir = p.join(repoRoot, 'assets', 'web');

  final wasmPackExe = _findWasmPack();
  if (wasmPackExe == null) {
    stderr.writeln(
      'Error: `wasm-pack` was not found in PATH or ~/.cargo/bin.\n'
      'Install via: cargo install wasm-pack',
    );
    exit(69);
  }

  final stagingDirectory = Directory(stagingDir);
  if (stagingDirectory.existsSync()) {
    stagingDirectory.deleteSync(recursive: true);
  }
  stagingDirectory.createSync(recursive: true);

  final wasmPackArgs = <String>[
    'build',
    '-t',
    'no-modules',
    '-d',
    stagingDir,
    '--no-typescript',
    '--out-name',
    'miniaudio_player',
    if (isDebug) '--dev',
    rustDir,
    '--',
    '-Z',
    'build-std=std,panic_abort',
  ];

  // Disable Cargo symbol stripping during the pre-wasm-bindgen compilation
  // step so the `target_features` custom section remains intact for
  // wasm-bindgen, then let wasm-pack's `wasm-opt` optimize the final binary.
  final env = <String, String>{
    ...Platform.environment,
    'RUSTUP_TOOLCHAIN': 'nightly',
    'CARGO_PROFILE_RELEASE_STRIP': 'none',
    'RUSTFLAGS': _webThreadedRustFlags,
  };

  stdout.writeln(
    'Building multi-threaded WebAssembly '
    '(${isDebug ? 'debug' : 'release'}) -> $stagingDir',
  );

  final process = await Process.start(
    wasmPackExe,
    wasmPackArgs,
    workingDirectory: repoRoot,
    environment: env,
    mode: ProcessStartMode.inheritStdio,
  );
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    stderr.writeln('Error: wasm-pack exited with code $exitCode.');
    exit(exitCode);
  }

  final outDir = Directory(assetsWebDir);
  if (outDir.existsSync()) {
    for (final entity in outDir.listSync()) {
      final name = p.basename(entity.path);
      if (!_distAssetNames.contains(name)) {
        entity.deleteSync(recursive: true);
      }
    }
  } else {
    outDir.createSync(recursive: true);
  }

  for (final name in _distAssetNames) {
    final src = File(p.join(stagingDir, name));
    if (!src.existsSync() || src.lengthSync() == 0) {
      stderr.writeln('Error: Expected WASM artifact missing or empty: ${src.path}');
      exit(70);
    }
    final dst = File(p.join(assetsWebDir, name));
    src.copySync(dst.path);
    final kib = (dst.lengthSync() / 1024).toStringAsFixed(1);
    stdout.writeln('Published assets/web/$name ($kib KiB)');
  }
}

String _resolveRepoRoot() {
  try {
    final scriptFile = File.fromUri(Platform.script);
    final parent = p.basename(scriptFile.parent.path);
    if (parent == 'tool') {
      return scriptFile.parent.parent.path;
    }
  } catch (_) {}
  return Directory.current.path;
}

String? _findWasmPack() {
  final exe = Platform.isWindows ? 'wasm-pack.exe' : 'wasm-pack';
  final pathEnv = Platform.environment['PATH'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  for (final dir in pathEnv.split(sep)) {
    if (dir.isEmpty) continue;
    final candidate = File(p.join(dir, exe));
    if (candidate.existsSync()) return candidate.path;
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.isNotEmpty) {
    final cargoCandidate = File(p.join(home, '.cargo', 'bin', exe));
    if (cargoCandidate.existsSync()) return cargoCandidate.path;
  }
  return null;
}
