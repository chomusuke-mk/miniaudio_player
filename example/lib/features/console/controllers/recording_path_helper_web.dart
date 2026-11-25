/// Creates a temporary OS file path for [fileName] on unsupported Web targets.
///
/// Web resolves relative and absolute recording paths automatically to OPFS,
/// so no temporary OS directory path is needed for [fileName]. Always throws
/// an [UnsupportedError] directing callers to OPFS or in-memory recording
/// buffers.
Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError(
    'Web uses OPFS relative/absolute paths or MemoryRecordingBuffer.',
  );
}
