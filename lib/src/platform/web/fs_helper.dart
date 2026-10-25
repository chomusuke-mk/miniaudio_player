import 'dart:async';
import 'dart:typed_data';

void allowHttpInTests() {}

bool isFsEntity(dynamic source) => false;

String? getFsPath(dynamic source) => null;

bool checkFileExists(String path) => true;

Uint8List? readBytesFromFile(String path) => null;

(Uint8List, int) readFileHeaderAndLength(String path, int maxHeaderBytes) {
  return (Uint8List(0), 0);
}

Future<Uint8List> readFileBytes(String path) async {
  throw UnsupportedError('Direct dart:io file reading is not supported on Web.');
}

Future<int> getFileLength(String path) async {
  throw UnsupportedError('Direct dart:io file length is not supported on Web.');
}

Stream<Uint8List> openFileStream(String path, {int offset = 0, int? length}) {
  throw UnsupportedError('Direct dart:io file stream is not supported on Web.');
}

Future<Uint8List> readFileRange(String path, int offset, int length) async {
  throw UnsupportedError('Direct dart:io file range is not supported on Web.');
}
