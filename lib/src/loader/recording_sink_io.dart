import 'dart:typed_data';

import 'recording_sink_stub.dart';

export 'recording_sink_stub.dart' show WebOpfsRecordingSession;

Future<WebOpfsRecordingSession> openWebOpfsRecordingSession(String path) {
  throw UnsupportedError('OPFS recording is only supported on Web.');
}

Uri? createWavBlobUriFromBytes(Uint8List wavBytes) => null;

void revokeRecordingBlobUri(Uri? uri) {}

bool isWebOpfsEnvironment() => false;
