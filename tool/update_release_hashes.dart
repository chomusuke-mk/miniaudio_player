import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Updates `_embeddedReleaseHashes` in `hook/build.dart` from a `checksums.sha256`
/// file produced by the GitHub Actions release matrix.
///
/// Usage:
///   `dart run tool/update_release_hashes.dart <path-to-checksums.sha256>`
void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/update_release_hashes.dart <path-to-checksums.sha256>',
    );
    exit(64);
  }

  final checksumsFile = File(args.first);
  if (!checksumsFile.existsSync()) {
    stderr.writeln('Error: ${checksumsFile.path} does not exist.');
    exit(66);
  }

  final entries = <String, String>{};
  for (final line in const LineSplitter().convert(
    checksumsFile.readAsStringSync(),
  )) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final match = RegExp(
      r'^([a-fA-F0-9]{64})\s+\*?(.+)$',
    ).firstMatch(trimmed);
    if (match != null) {
      entries[match.group(2)!.trim()] = match.group(1)!.toLowerCase();
    }
  }

  if (entries.isEmpty) {
    stderr.writeln('Error: No valid SHA-256 entries found in ${args.first}.');
    exit(65);
  }

  final hookFile = File(p.join('hook', 'build.dart'));
  if (!hookFile.existsSync()) {
    stderr.writeln('Error: hook/build.dart not found.');
    exit(66);
  }

  final sortedKeys = entries.keys.toList()..sort();
  final mapEntries =
      sortedKeys.map((k) => "  '$k':\n      '${entries[k]}',").join('\n');

  final replacement =
      'const Map<String, String> _embeddedReleaseHashes = <String, String>{\n'
      '$mapEntries\n'
      '};';

  final content = hookFile.readAsStringSync();
  final pattern = RegExp(
    r'const Map<String, String> _embeddedReleaseHashes = <String, String>\{[\s\S]*?\};',
  );
  if (!pattern.hasMatch(content)) {
    stderr.writeln(
      'Error: Could not find _embeddedReleaseHashes declaration in hook/build.dart.',
    );
    exit(65);
  }
  final updated = content.replaceFirst(pattern, replacement);

  hookFile.writeAsStringSync(updated);
  stdout.writeln(
    'Updated hook/build.dart with ${entries.length} embedded SHA-256 release hashes.',
  );
}
