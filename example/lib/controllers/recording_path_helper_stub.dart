import 'dart:typed_data';

Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError('Temporary filesystem recording paths are only created on IO targets.');
}

Uri? createWebRecordingBlobUri(
  Uint8List bytes, {
  String mimeType = 'audio/wav',
  String? fileName,
}) =>
    null;

void revokeWebRecordingBlobUri(Uri? uri) {}

bool triggerWebRecordingDownload(String uri, {String? fileName}) => false;
