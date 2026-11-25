import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';

/// Returns `true` when running in a browser context that exposes the Origin
/// Private File System (OPFS).
bool isWebOpfsSupported() => false;

/// Triggers a browser download for the OPFS recording at [path] using
/// [fileName] and [mimeType].
///
/// Always returns `false` on unsupported stub targets.
Future<bool> downloadOpfsRecordingFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Triggers a browser download from in-memory [chunks] using [fileName] and
/// [mimeType].
///
/// Always returns `false` on unsupported stub targets.
Future<bool> downloadMemoryRecordingBytes(
  List<Uint8List> chunks, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Reads all bytes from the Web OPFS recording located at [path].
///
/// Always throws [MiniaudioPlayerException] with
/// [MapResult.errorUnsupported] on unsupported stub targets.
Future<Uint8List> readOpfsRecordingBytes(String path) async {
  MapLogger.warn(
    'readOpfsRecordingBytes("$path") is unsupported on stub platform target.',
  );
  throw const MiniaudioPlayerException(
    'OPFS byte reads are only supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Reads all bytes from the native filesystem recording located at [path].
///
/// Always throws [MiniaudioPlayerException] with
/// [MapResult.errorUnsupported] on unsupported stub targets.
Future<Uint8List> readDiskRecordingBytes(String path) async {
  MapLogger.warn(
    'readDiskRecordingBytes("$path") is unsupported on stub platform target.',
  );
  throw const MiniaudioPlayerException(
    'Local disk byte reads are only supported on native IO targets.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Creates an on-demand `blob:` URI backed by the Web OPFS file at [path] with
/// [mimeType] and an optional [fileName] fragment.
///
/// Always returns `null` on unsupported stub targets.
Future<Uri?> createOpfsRecordingBlobUri(
  String path, {
  required String mimeType,
  String? fileName,
}) async =>
    null;

/// Creates an on-demand `blob:` URI backed by in-memory [chunks] with
/// [mimeType] and an optional [fileName] fragment.
///
/// Always returns `null` on unsupported stub targets.
Uri? createMemoryRecordingBlobUri(
  List<Uint8List> chunks, {
  required String mimeType,
  String? fileName,
}) =>
    null;

/// Revokes a Web `blob:` [uri] previously allocated by
/// `RecordingResult.createBlobUri`.
void revokeRecordingResultBlobUri(Uri? uri) {}

/// Checks whether a Web OPFS recording currently exists at [path].
///
/// Always returns `false` on unsupported stub targets.
Future<bool> opfsRecordingFileExists(String path) async => false;

/// Checks whether a native filesystem recording currently exists at [path].
///
/// Always returns `false` on unsupported stub targets.
Future<bool> diskRecordingFileExists(String path) async => false;

/// Deletes the Web OPFS recording at [path] if present.
///
/// Always returns `false` on unsupported stub targets.
Future<bool> deleteOpfsRecordingFile(String path) async => false;

/// Deletes the native filesystem recording at [path] if present.
///
/// Always returns `false` on unsupported stub targets.
Future<bool> deleteDiskRecordingFile(String path) async => false;

/// Saves a completed recording from [sourcePath] (where [sourceIsOpfs] indicates
/// OPFS origin) or [memoryChunks] to [destinationPath].
///
/// Always throws [MiniaudioPlayerException] with
/// [MapResult.errorUnsupported] on unsupported stub targets.
Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  MapLogger.warn(
    'saveRecordingToDestination("$destinationPath") is unsupported on stub platform target.',
  );
  throw const MiniaudioPlayerException(
    'saveTo() is unavailable on this stub platform target.',
    errorCode: MapResult.errorUnsupported,
  );
}
