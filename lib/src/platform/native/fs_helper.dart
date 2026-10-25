import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

void allowHttpInTests() {
  HttpOverrides.global = null;
}

bool isFsEntity(dynamic source) => source is FileSystemEntity;

String? getFsPath(dynamic source) {
  if (source is FileSystemEntity) return source.path;
  return null;
}

bool checkFileExists(String path) {
  return File(path).existsSync();
}

Uint8List? readBytesFromFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return file.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

(Uint8List, int) readFileHeaderAndLength(String path, int maxHeaderBytes) {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Audio file not found at path', path);
  }
  final raf = file.openSync(mode: FileMode.read);
  try {
    final len = raf.lengthSync();
    final toRead = len < maxHeaderBytes ? len : maxHeaderBytes;
    final header = toRead > 0 ? raf.readSync(toRead) : Uint8List(0);
    return (header, len);
  } finally {
    raf.closeSync();
  }
}

Future<Uint8List> readFileBytes(String path) async {
  return await File(path).readAsBytes();
}

Future<int> getFileLength(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Audio file not found at path', path);
  }
  if (FileSystemEntity.isDirectorySync(path)) {
    throw FileSystemException('Path is a directory, not an audio file', path);
  }
  return file.lengthSync();
}

Stream<Uint8List> openFileStream(String path, {int offset = 0, int? length}) {
  final file = File(path);
  final int? end = length != null ? offset + length : null;
  return file.openRead(offset, end).map(
        (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      );
}

Future<Uint8List> readFileRange(String path, int offset, int length) async {
  final file = File(path);
  final raf = await file.open(mode: FileMode.read);
  try {
    await raf.setPosition(offset);
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}
