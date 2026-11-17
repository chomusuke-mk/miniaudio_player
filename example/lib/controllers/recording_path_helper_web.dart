import 'dart:js_interop';
import 'dart:typed_data';

@JS('Blob')
extension type _WebBlob._(JSObject _) implements JSObject {
  external factory _WebBlob(JSArray<JSAny> parts, _WebBlobOptions options);
}

extension type _WebBlobOptions._(JSObject _) implements JSObject {
  external factory _WebBlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectUrl(_WebBlob blob);

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

/// Creates a downloadable/playable `audio/wav` `blob:` URI from recorded WAV bytes.
Uri? createWebRecordingBlobUri(Uint8List wavBytes) {
  if (wavBytes.isEmpty) return null;
  final copy = Uint8List.fromList(wavBytes);
  final parts = JSArray<JSAny>.withLength(1)..[0] = copy.buffer.toJS;
  final blob = _WebBlob(
    parts,
    _WebBlobOptions(type: 'audio/wav'),
  );
  return Uri.parse(_createObjectUrl(blob));
}

/// Revokes a `blob:` URI previously allocated for Web recording playback/open.
void revokeWebRecordingBlobUri(Uri? uri) {
  if (uri != null && uri.scheme == 'blob') {
    try {
      _revokeObjectUrl(uri.toString());
    } catch (_) {}
  }
}

/// Triggers a browser file download fallback for a recorded `blob:` URI when
/// `OpenFile.open` popup navigation is blocked or suppressed by COOP.
bool triggerWebRecordingDownload(String uri, {String? fileName}) {
  if (uri.isEmpty) return false;
  try {
    final anchor = _createAnchorElement('a');
    anchor.href = uri;
    anchor.download = (fileName != null && fileName.isNotEmpty)
        ? fileName
        : 'studio_recording.wav';
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
