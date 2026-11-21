/// Web resolves relative/absolute recording paths automatically to OPFS,
/// so no temporary OS directory path is needed.
Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError('Web uses OPFS relative/absolute paths or MemoryRecordingBuffer.');
}
