import 'dart:typed_data';

import '../api/player_exception.dart';

/// Returns `true` when running on a Web browser/context exposing Origin Private File System.
bool isWebOpfsSupported() => false;

/// Triggers a browser download of an OPFS recording (`false` on non-Web targets).
Future<bool> downloadOpfsRecordingFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Triggers a browser download from in-memory chunks (`false` on non-Web targets).
Future<bool> downloadMemoryRecordingBytes(
  List<Uint8List> chunks, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Reads all bytes from a Web OPFS recording path.
Future<Uint8List> readOpfsRecordingBytes(String path) async {
  throw const MiniaudioPlayerException(
    'OPFS byte reads are only supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Reads all bytes from a native filesystem recording path.
Future<Uint8List> readDiskRecordingBytes(String path) async {
  throw const MiniaudioPlayerException(
    'Local disk byte reads are only supported on native IO targets.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Creates an on-demand `blob:` URI backed by a Web OPFS file (`null` on non-Web).
Future<Uri?> createOpfsRecordingBlobUri(
  String path, {
  required String mimeType,
  String? fileName,
}) async =>
    null;

/// Creates an on-demand `blob:` URI backed by in-memory chunks (`null` on non-Web).
Uri? createMemoryRecordingBlobUri(
  List<Uint8List> chunks, {
  required String mimeType,
  String? fileName,
}) =>
    null;

/// Revokes a Web `blob:` URI previously allocated by [RecordingResult.createBlobUri].
void revokeRecordingResultBlobUri(Uri? uri) {}

/// Checks whether a Web OPFS recording currently exists.
Future<bool> opfsRecordingFileExists(String path) async => false;

/// Checks whether a native filesystem recording currently exists.
Future<bool> diskRecordingFileExists(String path) async => false;

/// Deletes a Web OPFS recording if present.
Future<bool> deleteOpfsRecordingFile(String path) async => false;

/// Deletes a native filesystem recording if present.
Future<bool> deleteDiskRecordingFile(String path) async => false;

/// Saves a completed recording to [destinationPath] and returns the canonical saved path.
Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  throw const MiniaudioPlayerException(
    'saveTo() is unavailable on this stub platform target.',
    errorCode: MapResult.errorUnsupported,
  );
}
