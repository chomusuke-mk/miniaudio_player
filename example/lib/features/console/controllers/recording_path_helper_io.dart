import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Creates a writable temporary recording file path for [fileName] on IO targets.
///
/// Resolves the temporary base directory via [getTemporaryDirectory] and falls
/// back cleanly to [Directory.systemTemp] when platform channels are
/// unavailable (such as headless unit tests), then creates a unique
/// subdirectory for [fileName].
Future<String> createTempRecordingFilePath(String fileName) async {
  Directory baseDir;
  try {
    baseDir = await getTemporaryDirectory();
  } catch (_) {
    baseDir = Directory.systemTemp;
  }
  final recDir = await baseDir.createTemp('miniaudio_player_example_');
  final sep = Platform.pathSeparator;
  final dirPath = recDir.path.endsWith(sep) ? recDir.path : '${recDir.path}$sep';
  return '$dirPath$fileName';
}
