import 'dart:async';
import 'dart:typed_data';

void allowHttpInTests() {}

bool isFsEntity(dynamic source) => false;

String? getFsPath(dynamic source) => null;

bool checkFileExists(String path) => true;

bool isDirectlyReadableRegularFile(String path) => false;

String? readFdSymbolicLink(int fd) => null;

int openNativeFd(String path) => -1;

(int, int)? createNativePipe() => null;

int writeNativeFd(int fd, Uint8List bytes) => -1;

int dupNativeFd(int fd) => -1;

bool closeNativeFdSync(int fd) => false;

bool isNativeFdSeekable(int fd) => false;

int getNativeFdLength(int fd) => -1;

Uint8List? preadNativeFd(int fd, int offset, int length) => null;

bool isNativeFdReadyToRead(int fd) => true;

Uint8List? readSequentialNativeFd(int fd, int maxBytes) => null;

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

Future<int> rafLength(dynamic handle) async {
  return await (handle.length() as FutureOr<int>);
}

Future<void> rafSetPosition(dynamic handle, int offset) async {
  await handle.setPosition(offset);
}

Future<Uint8List> rafRead(dynamic handle, int count) async {
  final res = await handle.read(count);
  return res is Uint8List ? res : Uint8List.fromList(res as List<int>);
}

Future<void> rafClose(dynamic handle) async {
  await handle.close();
}
