import 'dart:io';

import 'package:hooks/hooks.dart';

/// Decompresses a single-file `.gz` [sourceGz] stream into [destination] using
/// Dart's native `dart:io` `gzip` codec (zero external `tar` dependency).
Future<void> decompressGzipFile(File sourceGz, File destination) async {
  await destination.parent.create(recursive: true);
  final sink = destination.openWrite();
  var closed = false;
  try {
    await for (final chunk in gzip.decoder.bind(sourceGz.openRead())) {
      sink.add(chunk);
    }
    await sink.flush();
    closed = true;
    await sink.close();
  } catch (e) {
    if (!closed) {
      try {
        await sink.close();
      } catch (_) {}
    }
    if (destination.existsSync()) {
      try {
        destination.deleteSync();
      } catch (_) {}
    }
    throw InfraError(
      message: 'Failed to gunzip ${sourceGz.path} -> ${destination.path}: $e',
    );
  }
}
