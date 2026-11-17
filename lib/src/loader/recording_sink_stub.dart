import 'dart:typed_data';

import '../api/recording_byte_buffer.dart';

abstract interface class WebOpfsRecordingSession {
  String get normalizedPath;
  RecordingByteBuffer get buffer;
  Future<Uri?> finalizeBlobUri();
}

Future<WebOpfsRecordingSession> openWebOpfsRecordingSession(String path) {
  throw UnsupportedError('OPFS recording is only supported on Web.');
}

Uri? createWavBlobUriFromBytes(Uint8List wavBytes) => null;

void revokeRecordingBlobUri(Uri? uri) {}

bool isWebOpfsEnvironment() => false;
