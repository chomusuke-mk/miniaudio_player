import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves a writable native temporary directory for studio recordings,
/// falling back cleanly to [Directory.systemTemp] when platform channels
/// are unavailable (such as headless unit tests).
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
