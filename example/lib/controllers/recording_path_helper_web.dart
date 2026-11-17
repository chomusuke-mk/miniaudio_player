import 'dart:js_interop';
import 'dart:typed_data';

@JS('Blob')
extension type _WebBlob._(JSObject _) implements JSObject {
  external factory _WebBlob(JSArray<JSAny> parts, _WebBlobOptions options);
}

@JS('File')
extension type _WebFile._(JSObject _) implements JSObject {
  external factory _WebFile(
    JSArray<JSAny> parts,
    String fileName,
    _WebBlobOptions options,
  );
}

extension type _WebBlobOptions._(JSObject _) implements JSObject {
  external factory _WebBlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blobOrFile);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('document.createElement')
external _HtmlAnchorElement _createAnchorElement(String tagName);

@JS('document.body')
external _HtmlBodyElement? get _documentBody;

extension type _WebCssStyleDeclaration._(JSObject _) implements JSObject {
  external set display(String value);
}

extension type _HtmlAnchorElement._(JSObject _) implements JSObject {
  external set href(String value);
  external set download(String value);
  external set rel(String value);
  external _WebCssStyleDeclaration get style;
  external void click();
  external void remove();
}

extension type _HtmlBodyElement._(JSObject _) implements JSObject {
  external void appendChild(_HtmlAnchorElement node);
}

Future<String> createTempRecordingFilePath(String fileName) {
  throw UnsupportedError('Web uses MemoryRecordingBuffer or OPFS relative paths.');
}

String _sanitizeFileName(String? fileName) {
  final raw = (fileName ?? '').trim().split(RegExp(r'[/\\]')).last;
  if (raw.isEmpty) return 'studio_recording.wav';
  return raw.replaceAll(RegExp(r'[\x00-\x1f\x7f"<>|:*?\\/]'), '_');
}

Uri _withFileFragment(Uri uri, String safeName) => uri.replace(fragment: safeName);

/// Creates a `blob:` URI backed by a named `File` object and tagged with the
/// `#<fileName>` fragment so the visible URL carries the file name & extension.
Uri? createWebRecordingBlobUri(
  Uint8List bytes, {
  String mimeType = 'audio/wav',
  String? fileName,
}) {
  if (bytes.isEmpty) return null;
  final copy = Uint8List.fromList(bytes);
  final parts = JSArray<JSAny>.withLength(1)..[0] = copy.buffer.toJS;
  final opts = _WebBlobOptions(type: mimeType);
  final safeName = _sanitizeFileName(fileName);
  String objectUrl;
  try {
    objectUrl = _createObjectUrl(_WebFile(parts, safeName, opts));
  } catch (_) {
    objectUrl = _createObjectUrl(_WebBlob(parts, opts));
  }
  return _withFileFragment(Uri.parse(objectUrl), safeName);
}

/// Revokes a `blob:` URI previously allocated for Web recording playback/open.
void revokeWebRecordingBlobUri(Uri? uri) {
  if (uri != null && uri.scheme == 'blob') {
    try {
      _revokeObjectUrl(uri.toString().split('#').first);
    } catch (_) {}
  }
}

/// Triggers a direct browser download for a recording URI with exact [fileName].
bool triggerWebRecordingDownload(String uri, {String? fileName}) {
  if (uri.isEmpty) return false;
  try {
    final cleanUri = uri.split('#').first;
    final anchor = _createAnchorElement('a');
    anchor.href = cleanUri;
    anchor.download = _sanitizeFileName(fileName);
    anchor.rel = 'noopener';
    anchor.style.display = 'none';
    final body = _documentBody;
    if (body != null) {
      body.appendChild(anchor);
      anchor.click();
      anchor.remove();
    } else {
      anchor.click();
    }
    return true;
  } catch (_) {
    return false;
  }
}
