import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:path/path.dart' as p;

/// Parses Cargo's `.d` dep-info file and registers source dependencies
/// without triggering `hooks_runner` self-invalidation loops.
void registerSourceDependencies({
  required Uri rustRoot,
  required String cargoTargetDir,
  required String builtLibPath,
  required BuildOutputBuilder output,
}) {
  final normalizedTargetDir = p.normalize(cargoTargetDir);
  final depFile = File(p.setExtension(builtLibPath, '.d'));

  var parsedDepFile = false;
  if (depFile.existsSync()) {
    final normalizedContent = depFile
        .readAsStringSync()
        .replaceAll(RegExp(r'\\\r?\n'), ' ');
    for (final line in normalizedContent.split(RegExp(r'\r?\n'))) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;

      // Split on the FIRST ": " (with space) to preserve Windows C:\ drive letters.
      final sepIdx = trimmed.indexOf(': ');
      if (sepIdx == -1) continue;
      final target = trimmed
          .substring(0, sepIdx)
          .trim()
          .replaceAll(r'\ ', ' ');
      final normTarget = p.normalize(target);
      final normBuiltLib = p.normalize(builtLibPath);
      final matchesTarget = p.equals(normTarget, normBuiltLib) ||
          p.equals(
            p.withoutExtension(normTarget),
            p.withoutExtension(normBuiltLib),
          );
      if (!matchesTarget) continue;

      final depsRaw = trimmed.substring(sepIdx + 2).trim();
      for (final depPath in splitMakeDeps(depsRaw)) {
        final norm = p.normalize(depPath);
        // Never add `.d` files or files inside cargoTargetDir (prevents infinite rebuild loops).
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

  // Always explicitly register Cargo/toolchain configuration and C bridge files.
  for (final rel in [
    'Cargo.toml',
    'Cargo.lock',
    'build.rs',
    '.cargo/config.toml',
    'c_src/miniaudio.h',
    'c_src/miniaudio_device_bridge.h',
    'c_src/miniaudio_device_bridge.c',
  ]) {
    final f = File.fromUri(rustRoot.resolve(rel));
    if (f.existsSync()) {
      output.dependencies.add(f.uri);
    }
  }

  // Fallback if .d file wasn't found or contained no entries: scan rust/src/**/*.rs.
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

/// Splits Makefile/Cargo dep-info whitespace-separated paths while preserving escaped spaces (`\ `).
List<String> splitMakeDeps(String raw) {
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
