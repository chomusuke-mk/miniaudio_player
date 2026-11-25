/// Creates a temporary local file path for [fileName] on IO targets.
///
/// Always throws an [UnsupportedError] on stub platforms that lack both
/// `dart:io` and `dart:js_interop` support for [fileName] resolution.
Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError(
    'Temporary filesystem recording paths are only created on IO targets.',
  );
}
