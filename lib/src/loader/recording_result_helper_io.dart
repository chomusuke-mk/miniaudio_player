import 'dart:io';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';

/// Returns `true` when running in a browser context that exposes the Origin
/// Private File System (OPFS).
///
/// Always returns `false` on native IO targets.
bool isWebOpfsSupported() => false;

/// Triggers a browser download for the OPFS recording at [path] using
/// [fileName] and [mimeType].
///
/// Always returns `false` on native IO targets.
Future<bool> downloadOpfsRecordingFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Triggers a browser download from in-memory [chunks] using [fileName] and
/// [mimeType].
///
/// Always returns `false` on native IO targets.
Future<bool> downloadMemoryRecordingBytes(
  List<Uint8List> chunks, {
  required String fileName,
  required String mimeType,
}) async =>
    false;

/// Reads all bytes from the Web OPFS recording located at [path].
///
/// Always throws [MiniaudioPlayerException] with
/// [MapResult.errorUnsupported] on native IO targets.
Future<Uint8List> readOpfsRecordingBytes(String path) async {
  MapLogger.warn(
    'readOpfsRecordingBytes("$path") is unsupported on native IO targets.',
  );
  throw const MiniaudioPlayerException(
    'OPFS byte reads are only supported on Web.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Reads all bytes from the native filesystem recording located at [path].
///
/// Throws [MiniaudioPlayerException] if [path] is empty, uses an unsupported
/// Android `content://` URI, or does not exist on disk.
Future<Uint8List> readDiskRecordingBytes(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty) {
    MapLogger.error(
      'readDiskRecordingBytes failed: recording has no filesystem path.',
    );
    throw const MiniaudioPlayerException(
      'Cannot read bytes: recording has no filesystem path.',
      errorCode: MapResult.errorInvalidState,
    );
  }
  if (trimmed.toLowerCase().startsWith('content://')) {
    MapLogger.error(
      'readDiskRecordingBytes unsupported for Android content URI "$trimmed".',
    );
    throw MiniaudioPlayerException(
      'Direct raw byte reads from Android content:// URI "$trimmed" are not supported; '
      'pass AudioSource(res.path) directly for playback or analysis.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  final file = File(trimmed);
  if (!await file.exists()) {
    MapLogger.error(
      'readDiskRecordingBytes failed: file not found at "$trimmed".',
    );
    throw MiniaudioPlayerException(
      'Recorded file not found at "$trimmed".',
      errorCode: MapResult.errorFileNotFound,
    );
  }
  try {
    final bytes = await file.readAsBytes();
    MapLogger.debug(
      'Read ${bytes.length} bytes from disk recording "$trimmed".',
    );
    return bytes;
  } catch (e) {
    MapLogger.error(
      'readDiskRecordingBytes failed while reading "$trimmed": $e',
    );
    rethrow;
  }
}

/// Creates an on-demand `blob:` URI backed by the Web OPFS file at [path] with
/// [mimeType] and an optional [fileName] fragment.
///
/// Always returns `null` on native IO targets.
Future<Uri?> createOpfsRecordingBlobUri(
  String path, {
  required String mimeType,
  String? fileName,
}) async =>
    null;

/// Creates an on-demand `blob:` URI backed by in-memory [chunks] with
/// [mimeType] and an optional [fileName] fragment.
///
/// Always returns `null` on native IO targets.
Uri? createMemoryRecordingBlobUri(
  List<Uint8List> chunks, {
  required String mimeType,
  String? fileName,
}) =>
    null;

/// Revokes a Web `blob:` [uri] previously allocated by
/// `RecordingResult.createBlobUri`.
///
/// This is a no-op on native IO targets.
void revokeRecordingResultBlobUri(Uri? uri) {}

/// Checks whether a Web OPFS recording currently exists at [path].
///
/// Always returns `false` on native IO targets.
Future<bool> opfsRecordingFileExists(String path) async => false;

/// Checks whether a native filesystem recording currently exists at [path].
///
/// Returns `false` when [path] is empty or points to an Android `content://`
/// URI.
Future<bool> diskRecordingFileExists(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('content://')) {
    return false;
  }
  try {
    return await File(trimmed).exists();
  } catch (e) {
    MapLogger.warn(
      'diskRecordingFileExists check failed for "$trimmed": $e',
    );
    return false;
  }
}

/// Deletes the Web OPFS recording at [path] if present.
///
/// Always returns `false` on native IO targets.
Future<bool> deleteOpfsRecordingFile(String path) async => false;

/// Deletes the native filesystem recording at [path] if present.
///
/// Returns `true` if the file existed and was deleted, or `false` when [path]
/// is empty, uses an Android `content://` URI, or does not exist.
Future<bool> deleteDiskRecordingFile(String path) async {
  final trimmed = path.trim();
  if (trimmed.isEmpty || trimmed.toLowerCase().startsWith('content://')) {
    return false;
  }
  final file = File(trimmed);
  try {
    if (!await file.exists()) return false;
    await file.delete();
    MapLogger.debug('Deleted disk recording file "$trimmed".');
    return true;
  } catch (e) {
    MapLogger.error(
      'deleteDiskRecordingFile failed for "$trimmed": $e',
    );
    rethrow;
  }
}

/// Saves a completed recording from [memoryChunks] or [sourcePath] to
/// [destinationPath] and returns the resulting filesystem path.
///
/// The [sourceIsOpfs] flag is part of the cross-platform contract and is
/// ignored on native IO targets when [memoryChunks] or a disk [sourcePath] is
/// provided.
Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  final trimmedDest = destinationPath.trim();
  if (trimmedDest.isEmpty) {
    MapLogger.error(
      'saveRecordingToDestination failed: destination path is empty.',
    );
    throw const MiniaudioPlayerException(
      'Destination path cannot be empty.',
      errorCode: MapResult.errorInvalidArgs,
    );
  }
  final destFile = File(trimmedDest);
  try {
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
      MapLogger.info(
        'Saved in-memory recording (${memoryChunks.length} chunks) to "${destFile.path}".',
      );
      return destFile.path;
    }

    final trimmedSrc = sourcePath.trim();
    if (trimmedSrc.isEmpty) {
      MapLogger.error(
        'saveRecordingToDestination failed: no source path or in-memory buffer available.',
      );
      throw const MiniaudioPlayerException(
        'Cannot save recording: no source path or in-memory buffer available.',
        errorCode: MapResult.errorInvalidState,
      );
    }
    if (trimmedSrc.toLowerCase().startsWith('content://')) {
      MapLogger.error(
        'saveRecordingToDestination unsupported for Android content URI "$trimmedSrc".',
      );
      throw MiniaudioPlayerException(
        'Copying directly from Android content:// URI "$trimmedSrc" via File IO is not supported.',
        errorCode: MapResult.errorUnsupported,
      );
    }
    final srcFile = File(trimmedSrc);
    if (!await srcFile.exists()) {
      MapLogger.error(
        'saveRecordingToDestination failed: source file not found at "$trimmedSrc".',
      );
      throw MiniaudioPlayerException(
        'Recorded source file not found at "$trimmedSrc".',
        errorCode: MapResult.errorFileNotFound,
      );
    }
    await srcFile.copy(destFile.path);
    MapLogger.info(
      'Copied recording from "$trimmedSrc" to "${destFile.path}" (sourceIsOpfs=$sourceIsOpfs).',
    );
    return destFile.path;
  } catch (e) {
    if (e is! MiniaudioPlayerException) {
      MapLogger.error(
        'saveRecordingToDestination failed writing "${destFile.path}": $e',
      );
    }
    rethrow;
  }
}
