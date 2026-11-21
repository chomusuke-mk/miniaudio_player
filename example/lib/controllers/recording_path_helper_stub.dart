/// Resolves a temporary local file path for studio recordings on IO targets.
Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError('Temporary filesystem recording paths are only created on IO targets.');
}
