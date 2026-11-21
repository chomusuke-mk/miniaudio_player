import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import '../resolver/source_resolver_common.dart';

@JS('navigator.storage')
external JSAny? get _rawNavigatorStorage;

@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blobOrFile);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('document.createElement')
external _HtmlAnchorElement _createAnchorElement(String tagName);

@JS('document.body')
external _HtmlBodyElement? get _documentBody;

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

extension type _OpfsStorageManager._(JSObject _) implements JSObject {
  external JSPromise<_OpfsDirHandle> getDirectory();
}

extension type _OpfsGetHandleOpts._(JSObject _) implements JSObject {
  external factory _OpfsGetHandleOpts({bool create});
}

extension type _OpfsCreateWritableOpts._(JSObject _) implements JSObject {
  external factory _OpfsCreateWritableOpts({bool keepExistingData});
}

extension type _OpfsDirHandle._(JSObject _) implements JSObject {
  external JSPromise<_OpfsDirHandle> getDirectoryHandle(
    String name,
    _OpfsGetHandleOpts options,
  );
  external JSPromise<_OpfsFileHandle> getFileHandle(
    String name,
    _OpfsGetHandleOpts options,
  );
  external JSPromise<JSAny?> removeEntry(String name);
}

extension type _OpfsFileHandle._(JSObject _) implements JSObject {
  external JSPromise<_OpfsReadableFile> getFile();
  external JSPromise<_OpfsWritableStream> createWritable(
    _OpfsCreateWritableOpts options,
  );
}

extension type _OpfsReadableFile._(JSObject _) implements JSObject {
  external int get size;
  external _WebBlob slice(int start, int end, String contentType);
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

extension type _OpfsWritableStream._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> write(JSAny data);
  external JSPromise<JSAny?> close();
}

bool isWebOpfsSupported() {
  try {
    final storage = _rawNavigatorStorage;
    if (storage == null || storage.isUndefinedOrNull) return false;
    final obj = storage as JSObject;
    final fn = obj.getProperty('getDirectory'.toJS);
    return fn.typeofEquals('function');
  } catch (_) {
    return false;
  }
}

Never _rethrowOpfsError(Object error, String path) {
  if (error is MiniaudioPlayerException) throw error;
  final msg = error.toString();
  final lower = msg.toLowerCase();
  if (lower.contains('notfounderror')) {
    throw MiniaudioPlayerException(
      'OPFS file not found at "$path".',
      errorCode: MapResult.errorFileNotFound,
      details: msg,
    );
  }
  if (lower.contains('notallowederror')) {
    throw MiniaudioPlayerException(
      'OPFS access denied for "$path": $msg',
      errorCode: MapResult.errorAccessDenied,
      details: msg,
    );
  }
  if (lower.contains('nomodificationallowederror')) {
    throw MiniaudioPlayerException(
      'OPFS file "$path" is currently locked by another active writer.',
      errorCode: MapResult.errorBusy,
      details: msg,
    );
  }
  if (lower.contains('typemismatcherror') || lower.contains('invalidname')) {
    throw MiniaudioPlayerException(
      'Invalid OPFS path "$path": $msg',
      errorCode: MapResult.errorInvalidArgs,
      details: msg,
    );
  }
  if (lower.contains('securityerror') ||
      lower.contains('notsupportederror') ||
      lower.contains('getdirectory is not a function')) {
    throw MiniaudioPlayerException(
      'Origin Private File System (OPFS) is unsupported or blocked in this browser context: $msg',
      errorCode: MapResult.errorUnsupported,
      details: msg,
    );
  }
  throw MiniaudioPlayerException(
    'OPFS operation failed for "$path": $msg',
    errorCode: MapResult.errorGeneric,
    details: msg,
  );
}

List<String> _strictOpfsSegments(String path) {
  final parsed = parseOpfsPathStrict(path);
  if (parsed.hasError) {
    throw MiniaudioPlayerException(
      parsed.errorMessage ?? 'Invalid OPFS path "$path".',
      errorCode: parsed.errorCode ?? MapResult.errorInvalidArgs,
    );
  }
  return parsed.canonicalPath!.split('/');
}

Future<({_OpfsDirHandle parent, String leaf})> _resolveParentDir(
  List<String> segments, {
  required bool createDirs,
}) async {
  if (!isWebOpfsSupported()) {
    throw const MiniaudioPlayerException(
      'Origin Private File System (OPFS) is unavailable in this browser context.',
      errorCode: MapResult.errorUnsupported,
    );
  }
  final storage = _rawNavigatorStorage! as _OpfsStorageManager;
  var dir = await storage.getDirectory().toDart;
  final opts = _OpfsGetHandleOpts(create: createDirs);
  for (var i = 0; i < segments.length - 1; i++) {
    dir = await dir.getDirectoryHandle(segments[i], opts).toDart;
  }
  return (parent: dir, leaf: segments.last);
}

Future<_OpfsFileHandle> _resolveOpfsFileHandle(
  String path, {
  required bool create,
}) async {
  final segments = _strictOpfsSegments(path);
  try {
    final resolved = await _resolveParentDir(segments, createDirs: create);
    return await resolved.parent
        .getFileHandle(resolved.leaf, _OpfsGetHandleOpts(create: create))
        .toDart;
  } catch (e) {
    _rethrowOpfsError(e, path);
  }
}

String _sanitizeDownloadName(String? fileName) {
  final raw = (fileName ?? '').trim().split(RegExp(r'[/\\]')).last;
  if (raw.isEmpty) return 'recording.wav';
  return raw.replaceAll(RegExp(r'[\x00-\x1f\x7f"<>|:*?\\/]'), '_');
}

JSArray<JSAny> _jsPartsFromChunks(List<Uint8List> chunks) {
  final parts = JSArray<JSAny>.withLength(chunks.length);
  for (var i = 0; i < chunks.length; i++) {
    // Copy chunk bytes cleanly in case a view uses a sub-range offset or shared buffer.
    final copy = Uint8List.fromList(chunks[i]);
    parts[i] = copy.buffer.toJS;
  }
  return parts;
}

bool _triggerAnchorDownload(String rawObjectUrl, String fileName) {
  try {
    final cleanUri = rawObjectUrl.split('#').first;
    final anchor = _createAnchorElement('a');
    anchor.href = cleanUri;
    anchor.download = _sanitizeDownloadName(fileName);
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

void _scheduleAutoRevoke(String objectUrl) {
  Timer(const Duration(seconds: 10), () {
    try {
      _revokeObjectUrl(objectUrl.split('#').first);
    } catch (_) {}
  });
}

Future<bool> downloadOpfsRecordingFile(
  String path, {
  required String fileName,
  required String mimeType,
}) async {
  final uri = await createOpfsRecordingBlobUri(
    path,
    mimeType: mimeType,
    fileName: fileName,
  );
  if (uri == null) return false;
  final rawUrl = uri.toString();
  final ok = _triggerAnchorDownload(rawUrl, fileName);
  _scheduleAutoRevoke(rawUrl);
  return ok;
}

Future<bool> downloadMemoryRecordingBytes(
  List<Uint8List> chunks, {
  required String fileName,
  required String mimeType,
}) async {
  final uri = createMemoryRecordingBlobUri(
    chunks,
    mimeType: mimeType,
    fileName: fileName,
  );
  if (uri == null) return false;
  final rawUrl = uri.toString();
  final ok = _triggerAnchorDownload(rawUrl, fileName);
  _scheduleAutoRevoke(rawUrl);
  return ok;
}

Future<Uint8List> readOpfsRecordingBytes(String path) async {
  final handle = await _resolveOpfsFileHandle(path, create: false);
  try {
    final file = await handle.getFile().toDart;
    final ab = await file.arrayBuffer().toDart;
    return ab.toDart.asUint8List();
  } catch (e) {
    _rethrowOpfsError(e, path);
  }
}

Future<Uint8List> readDiskRecordingBytes(String path) async {
  throw const MiniaudioPlayerException(
    'Native disk reads are unsupported on Web; use OPFS paths or readBytes() on isOpfs results.',
    errorCode: MapResult.errorUnsupported,
  );
}

Future<Uri?> createOpfsRecordingBlobUri(
  String path, {
  required String mimeType,
  String? fileName,
}) async {
  final handle = await _resolveOpfsFileHandle(path, create: false);
  try {
    final file = await handle.getFile().toDart;
    // Slice with explicit MIME type stays disk-backed in O(1) RAM.
    final typedBlob = file.slice(0, file.size, mimeType);
    final url = _createObjectUrl(typedBlob);
    final parsed = Uri.parse(url);
    final safe = _sanitizeDownloadName(fileName ?? path);
    return parsed.replace(fragment: safe);
  } catch (e) {
    _rethrowOpfsError(e, path);
  }
}

Uri? createMemoryRecordingBlobUri(
  List<Uint8List> chunks, {
  required String mimeType,
  String? fileName,
}) {
  var totalBytes = 0;
  for (final c in chunks) {
    totalBytes += c.length;
  }
  if (totalBytes == 0) return null;
  final parts = _jsPartsFromChunks(chunks);
  final opts = _WebBlobOptions(type: mimeType);
  final safeName = _sanitizeDownloadName(fileName);
  String objectUrl;
  try {
    objectUrl = _createObjectUrl(_WebFile(parts, safeName, opts));
  } catch (_) {
    objectUrl = _createObjectUrl(_WebBlob(parts, opts));
  }
  return Uri.parse(objectUrl).replace(fragment: safeName);
}

void revokeRecordingResultBlobUri(Uri? uri) {
  if (uri != null && uri.scheme == 'blob') {
    try {
      _revokeObjectUrl(uri.toString().split('#').first);
    } catch (_) {}
  }
}

Future<bool> opfsRecordingFileExists(String path) async {
  if (!isWebOpfsSupported()) return false;
  try {
    await _resolveOpfsFileHandle(path, create: false);
    return true;
  } on MiniaudioPlayerException catch (e) {
    if (e.errorCode == MapResult.errorFileNotFound) return false;
    rethrow;
  }
}

Future<bool> diskRecordingFileExists(String path) async => false;

Future<bool> deleteOpfsRecordingFile(String path) async {
  if (!isWebOpfsSupported()) return false;
  final segments = _strictOpfsSegments(path);
  try {
    final resolved = await _resolveParentDir(segments, createDirs: false);
    await resolved.parent.removeEntry(resolved.leaf).toDart;
    return true;
  } catch (e) {
    final lower = e.toString().toLowerCase();
    if (lower.contains('notfounderror')) return false;
    _rethrowOpfsError(e, path);
  }
}

Future<bool> deleteDiskRecordingFile(String path) async => false;

Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  final parsed = sanitizeOpfsRecordingPath(destinationPath);
  if (parsed.hadOpfsPrefix &&
      parsed.errorCode != MapResult.errorUnsupported) {
    MapLogger.logRedundantOpfsPrefix(
      destinationPath,
      canonicalPath: parsed.hasError ? null : parsed.canonicalPath,
    );
  }
  if (parsed.hasError) {
    throw MiniaudioPlayerException(
      parsed.errorMessage ?? 'Invalid OPFS destination path "$destinationPath".',
      errorCode: parsed.errorCode ?? MapResult.errorInvalidArgs,
    );
  }
  final canonicalDest = parsed.canonicalPath!;
  if (!isWebOpfsSupported()) {
    throw const MiniaudioPlayerException(
      'Origin Private File System (OPFS) is unavailable in this browser context.',
      errorCode: MapResult.errorUnsupported,
    );
  }

  final Uint8List payload;
  if (memoryChunks != null) {
    var total = 0;
    for (final c in memoryChunks) {
      total += c.length;
    }
    payload = Uint8List(total);
    var off = 0;
    for (final c in memoryChunks) {
      if (c.isNotEmpty) {
        payload.setRange(off, off + c.length, c);
        off += c.length;
      }
    }
  } else if (sourceIsOpfs && sourcePath.isNotEmpty) {
    payload = await readOpfsRecordingBytes(sourcePath);
  } else {
    throw const MiniaudioPlayerException(
      'Cannot save recording: no source OPFS path or in-memory buffer available.',
      errorCode: MapResult.errorInvalidState,
    );
  }

  final destHandle = await _resolveOpfsFileHandle(canonicalDest, create: true);
  try {
    final writableFn = (destHandle as JSObject).getProperty('createWritable'.toJS);
    if (!writableFn.typeofEquals('function')) {
      throw const MiniaudioPlayerException(
        'OPFS FileSystemWritableFileStream is unsupported in this browser for saveTo().',
        errorCode: MapResult.errorUnsupported,
      );
    }
    final writable = await destHandle
        .createWritable(_OpfsCreateWritableOpts(keepExistingData: false))
        .toDart;
    try {
      await writable.write(Uint8List.fromList(payload).toJS).toDart;
      await writable.close().toDart;
    } catch (_) {
      try {
        await writable.close().toDart;
      } catch (_) {}
      rethrow;
    }
    return canonicalDest;
  } catch (e) {
    _rethrowOpfsError(e, canonicalDest);
  }
}
