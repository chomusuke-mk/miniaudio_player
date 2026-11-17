import 'dart:typed_data';

import 'recording_sink_stub.dart';

export 'recording_sink_stub.dart' show WebOpfsRecordingSession;

Future<WebOpfsRecordingSession> openWebOpfsRecordingSession(
  String path, {
  String mimeType = 'audio/wav',
}) {
  throw UnsupportedError('OPFS recording is only supported on Web.');
}

Uri? createWavBlobUriFromBytes(
  Uint8List wavBytes, {
  String mimeType = 'audio/wav',
}) =>
    null;

void revokeRecordingBlobUri(Uri? uri) {}

bool isWebOpfsEnvironment() => false;
