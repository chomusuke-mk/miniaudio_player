import 'dart:io';
import 'dart:typed_data';

import '../api/player_exception.dart';

bool isWebOpfsSupported() => false;

Future<bool> downloadOpfsRecordingFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

Future<bool> downloadMemoryRecordingBytes(
  List<Uint8List> chunks, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

Future<Uint8List> readOpfsRecordingBytes(String path) async {
  throw const MiniaudioPlayerException(
    'OPFS byte reads are only supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}

Future<Uint8List> readDiskRecordingBytes(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    throw const MiniaudioPlayerException(
      'Cannot read bytes: recording has no filesystem path.',
      errorCode: MapResult.errorInvalidState,
    );
  }
  if (trimmed.toLowerCase().startsWith('content://')) {
    throw MiniaudioPlayerException(
      'Direct raw byte reads from Android content:// URI "$trimmed" are not supported; '
      'pass AudioSource(res.path) directly for playback or analysis.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  final file = File(trimmed);
  if (!await file.exists()) {
    throw MiniaudioPlayerException(
      'Recorded file not found at "$trimmed".',
      errorCode: MapResult.errorFileNotFound,
    );
  }
  return await file.readAsBytes();
}

Future<Uri?> createOpfsRecordingBlobUri(
  String path, {
  required String mimeType,
  String? fileName,
}) async =>
    null;

Uri? createMemoryRecordingBlobUri(
  List<Uint8List> chunks, {
  required String mimeType,
  String? fileName,
}) =>
    null;

void revokeRecordingResultBlobUri(Uri? uri) {}

Future<bool> opfsRecordingFileExists(String path) async => false;

Future<bool> diskRecordingFileExists(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('content://')) {
    return false;
  }
  return File(trimmed).exists();
}

Future<bool> deleteOpfsRecordingFile(String path) async => false;

Future<bool> deleteDiskRecordingFile(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('content://')) {
    return false;
  }
  final file = File(trimmed);
  if (!await file.exists()) return false;
  await file.delete();
  return true;
}

Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  final trimmedDest = destinationPath.trim();
  if (trimmedDest.isEmpty) {
    throw const MiniaudioPlayerException(
      'Destination path cannot be empty.',
      errorCode: MapResult.errorInvalidArgs,
    );
  }
  final destFile = File(trimmedDest);
  await destFile.parent.create(recursive: true);

  if (memoryChunks != null) {
    final sink = destFile.openWrite();
    try {
      for (final chunk in memoryChunks) {
        if (chunk.isNotEmpty) sink.add(chunk);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return destFile.path;
  }

  final trimmedSrc = sourcePath.trim();
  if (trimmedSrc.isEmpty) {
    throw const MiniaudioPlayerException(
      'Cannot save recording: no source path or in-memory buffer available.',
      errorCode: MapResult.errorInvalidState,
    );
  }
  if (trimmedSrc.toLowerCase().startsWith('content://')) {
    throw MiniaudioPlayerException(
      'Copying directly from Android content:// URI "$trimmedSrc" via File IO is not supported.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  final srcFile = File(trimmedSrc);
  if (!await srcFile.exists()) {
    throw MiniaudioPlayerException(
      'Recorded source file not found at "$trimmedSrc".',
      errorCode: MapResult.errorFileNotFound,
    );
  }
  await srcFile.copy(destFile.path);
  return destFile.path;
}
