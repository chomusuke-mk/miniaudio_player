import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import '../resolver/source_resolver_common.dart';

/// Raw JS `navigator.storage` reference used for OPFS capability detection.
@JS('navigator.storage')
external JSAny? get _rawNavigatorStorage;

/// Creates a `blob:` object URL for [blobOrFile] via `URL.createObjectURL`.
@JS('URL.createObjectURL')
external String _createObjectUrl(JSObject blobOrFile);

/// Revokes a `blob:` object [url] via `URL.revokeObjectURL`.
@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

/// Creates a DOM element for [tagName] via `document.createElement`.
@JS('document.createElement')
external _HtmlAnchorElement _createAnchorElement(String tagName);

/// Returns the current `document.body` element, or `null` when unavailable.
@JS('document.body')
external _HtmlBodyElement? get _documentBody;

/// JS `Blob` wrapper for assembling in-memory downloads and object URLs.
@JS('Blob')
extension type _WebBlob._(JSObject _) implements JSObject {
  /// Constructs a `Blob` from binary [parts] and [options].
  external factory _WebBlob(JSArray<JSAny> parts, _WebBlobOptions options);
}

/// JS `File` wrapper attaching a filename to binary blob parts.
@JS('File')
extension type _WebFile._(JSObject _) implements JSObject {
  /// Constructs a `File` from binary [parts], [fileName], and [options].
  external factory _WebFile(
    JSArray<JSAny> parts,
    String fileName,
    _WebBlobOptions options,
  );
}

/// Options object passed to [_WebBlob.new] and [_WebFile.new].
extension type _WebBlobOptions._(JSObject _) implements JSObject {
  /// Constructs blob options specifying the MIME [type].
  external factory _WebBlobOptions({String type});
}

/// Minimal JS interop view over `CSSStyleDeclaration`.
extension type _WebCssStyleDeclaration._(JSObject _) implements JSObject {
  /// Sets the CSS `display` property to [value].
  external set display(String value);
}

/// Minimal JS interop view over `HTMLAnchorElement` for triggering downloads.
extension type _HtmlAnchorElement._(JSObject _) implements JSObject {
  /// Sets the anchor target URL to [value].
  external set href(String value);

  /// Sets the suggested download filename to [value].
  external set download(String value);

  /// Sets the `rel` link relationship attribute to [value].
  external set rel(String value);

  /// Returns the inline CSS style declaration for this anchor element.
  external _WebCssStyleDeclaration get style;

  /// Programmatically activates the anchor click event.
  external void click();

  /// Removes this anchor element from the DOM.
  external void remove();
}

/// Minimal JS interop view over `HTMLBodyElement`.
extension type _HtmlBodyElement._(JSObject _) implements JSObject {
  /// Appends [node] as a child of the document body.
  external void appendChild(_HtmlAnchorElement node);
}

/// Minimal JS interop view over `StorageManager` for OPFS root access.
extension type _OpfsStorageManager._(JSObject _) implements JSObject {
  /// Resolves the root OPFS directory handle.
  external JSPromise<_OpfsDirHandle> getDirectory();
}

/// Options object passed to OPFS directory and file handle lookups.
extension type _OpfsGetHandleOpts._(JSObject _) implements JSObject {
  /// Constructs OPFS handle lookup options with [create] controlling entry
  /// creation.
  external factory _OpfsGetHandleOpts({bool create});
}

/// Options object passed to `FileSystemFileHandle.createWritable`.
extension type _OpfsCreateWritableOpts._(JSObject _) implements JSObject {
  /// Constructs writable stream options where [keepExistingData] controls
  /// whether existing file contents are preserved.
  external factory _OpfsCreateWritableOpts({bool keepExistingData});
}

/// Minimal JS interop view over `FileSystemDirectoryHandle`.
extension type _OpfsDirHandle._(JSObject _) implements JSObject {
  /// Resolves a subdirectory handle named [name] using [options].
  external JSPromise<_OpfsDirHandle> getDirectoryHandle(
    String name,
    _OpfsGetHandleOpts options,
  );

  /// Resolves a file handle named [name] using [options].
  external JSPromise<_OpfsFileHandle> getFileHandle(
    String name,
    _OpfsGetHandleOpts options,
  );

  /// Removes the entry named [name] from this directory.
  external JSPromise<JSAny?> removeEntry(String name);
}

/// Minimal JS interop view over `FileSystemFileHandle`.
extension type _OpfsFileHandle._(JSObject _) implements JSObject {
  /// Resolves a readable `File` snapshot for this handle.
  external JSPromise<_OpfsReadableFile> getFile();

  /// Opens a writable stream for this handle configured by [options].
  external JSPromise<_OpfsWritableStream> createWritable(
    _OpfsCreateWritableOpts options,
  );
}

/// Minimal JS interop view over a readable OPFS `File`.
extension type _OpfsReadableFile._(JSObject _) implements JSObject {
  /// Returns the file size in bytes.
  external int get size;

  /// Creates a lazy [_WebBlob] slice from byte [start] to [end] tagged with
  /// [contentType].
  external _WebBlob slice(int start, int end, String contentType);

  /// Reads the entire file contents into a `JSArrayBuffer`.
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

/// Minimal JS interop view over `FileSystemWritableFileStream`.
extension type _OpfsWritableStream._(JSObject _) implements JSObject {
  /// Writes [data] to the underlying OPFS file stream.
  external JSPromise<JSAny?> write(JSAny data);

  /// Flushes and closes the writable OPFS stream.
  external JSPromise<JSAny?> close();
}

/// Returns `true` when running in a browser context that exposes the Origin
/// Private File System (OPFS).
bool isWebOpfsSupported() {
  try {
    final storage = _rawNavigatorStorage;
    if (storage == null || storage.isUndefinedOrNull) return false;
    final obj = storage as JSObject;
    final fn = obj.getProperty('getDirectory'.toJS);
    return fn.typeofEquals('function');
  } catch (e) {
    MapLogger.debug('OPFS capability probe failed: $e');
    return false;
  }
}

/// Maps a browser OPFS [error] on [path] to a typed [MiniaudioPlayerException]
/// and rethrows it after logging.
Never _rethrowOpfsError(Object error, String path) {
  if (error is MiniaudioPlayerException) throw error;
  final msg = error.toString();
  final lower = msg.toLowerCase();
  MapLogger.error('OPFS operation failed for "$path": $msg');
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

/// Validates and splits an OPFS [path] into canonical path segments.
List<String> _strictOpfsSegments(String path) {
  final parsed = parseOpfsPathStrict(path);
  if (parsed.hasError) {
    MapLogger.error(
      'Invalid OPFS path "$path": ${parsed.errorMessage ?? 'unknown error'}',
    );
    throw MiniaudioPlayerException(
      parsed.errorMessage ?? 'Invalid OPFS path "$path".',
      errorCode: parsed.errorCode ?? MapResult.errorInvalidArgs,
    );
  }
  return parsed.canonicalPath!.split('/');
}

/// Traverses [segments] from the OPFS root to resolve the parent directory
/// handle and leaf filename, creating intermediate directories when
/// [createDirs] is `true`.
Future<({_OpfsDirHandle parent, String leaf})> _resolveParentDir(
  List<String> segments, {
  required bool createDirs,
}) async {
  if (!isWebOpfsSupported()) {
    MapLogger.error(
        'OPFS unavailable while resolving "${segments.join('/')}".');
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

/// Resolves the OPFS file handle for [path], creating the file and parent
/// directories when [create] is `true`.
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

/// Sanitizes [fileName] into a safe browser download filename, defaulting to
/// `'recording.wav'` when empty.
String _sanitizeDownloadName(String? fileName) {
  final raw = (fileName ?? '').trim().split(RegExp(r'[/\\]')).last;
  if (raw.isEmpty) return 'recording.wav';
  return raw.replaceAll(RegExp(r'[\x00-\x1f\x7f"<>|:*?\\/]'), '_');
}

/// Copies byte [chunks] into a `JSArray` of detached `ArrayBuffer` parts
/// suitable for `Blob` or `File` construction.
JSArray<JSAny> _jsPartsFromChunks(List<Uint8List> chunks) {
  final parts = JSArray<JSAny>.withLength(chunks.length);
  for (var i = 0; i < chunks.length; i++) {
    // Copy chunk bytes cleanly in case a view uses a sub-range offset or shared buffer.
    final copy = Uint8List.fromList(chunks[i]);
    parts[i] = copy.buffer.toJS;
  }
  return parts;
}

/// Triggers a hidden `<a download>` click for [rawObjectUrl] using [fileName]
/// and returns `true` when dispatched.
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
  } catch (e) {
    MapLogger.warn('Failed to trigger anchor download for "$fileName": $e');
    return false;
  }
}

/// Schedules revocation of [objectUrl] after 10 seconds so browser downloads
/// have time to initiate before the handle is released.
void _scheduleAutoRevoke(String objectUrl) {
  Timer(const Duration(seconds: 10), () {
    try {
      _revokeObjectUrl(objectUrl.split('#').first);
    } catch (e) {
      MapLogger.debug('Failed to auto-revoke blob URL: $e');
    }
  });
}

/// Triggers a browser download for the OPFS recording at [path] using
/// [fileName] and [mimeType].
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
  MapLogger.debug(
    'Triggered OPFS recording download for "$path" as "$fileName" (ok=$ok).',
  );
  return ok;
}

/// Triggers a browser download from in-memory [chunks] using [fileName] and
/// [mimeType].
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
  MapLogger.debug(
    'Triggered memory recording download as "$fileName" (ok=$ok).',
  );
  return ok;
}

/// Reads all bytes from the Web OPFS recording located at [path].
Future<Uint8List> readOpfsRecordingBytes(String path) async {
  final handle = await _resolveOpfsFileHandle(path, create: false);
  try {
    final file = await handle.getFile().toDart;
    final ab = await file.arrayBuffer().toDart;
    final bytes = ab.toDart.asUint8List();
    MapLogger.debug('Read ${bytes.length} bytes from OPFS recording "$path".');
    return bytes;
  } catch (e) {
    _rethrowOpfsError(e, path);
  }
}

/// Rejects native disk reads on Web for [path].
///
/// Always throws [MiniaudioPlayerException] with
/// [MapResult.errorUnsupported].
Future<Uint8List> readDiskRecordingBytes(String path) async {
  MapLogger.warn(
    'readDiskRecordingBytes("$path") is unsupported on Web; use OPFS paths.',
  );
  throw const MiniaudioPlayerException(
    'Native disk reads are unsupported on Web; use OPFS paths or readBytes() on isOpfs results.',
    errorCode: MapResult.errorUnsupported,
  );
}

/// Creates an on-demand `blob:` URI backed by the Web OPFS file at [path] with
/// [mimeType] and an optional [fileName] fragment.
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
    MapLogger.debug('Created OPFS blob URI for "$path" ($mimeType).');
    return parsed.replace(fragment: safe);
  } catch (e) {
    _rethrowOpfsError(e, path);
  }
}

/// Creates an on-demand `blob:` URI backed by in-memory [chunks] with
/// [mimeType] and an optional [fileName] fragment.
///
/// Returns `null` when [chunks] contain zero bytes.
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
  } catch (e) {
    MapLogger.debug(
      'Web File constructor failed, falling back to Blob for "$safeName": $e',
    );
    objectUrl = _createObjectUrl(_WebBlob(parts, opts));
  }
  MapLogger.debug(
    'Created in-memory blob URI ($totalBytes bytes, $mimeType).',
  );
  return Uri.parse(objectUrl).replace(fragment: safeName);
}

/// Revokes a Web `blob:` [uri] previously allocated by
/// `RecordingResult.createBlobUri`.
void revokeRecordingResultBlobUri(Uri? uri) {
  if (uri != null && uri.scheme == 'blob') {
    try {
      _revokeObjectUrl(uri.toString().split('#').first);
    } catch (e) {
      MapLogger.debug('Failed to revoke blob URI "$uri": $e');
    }
  }
}

/// Checks whether a Web OPFS recording currently exists at [path].
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

/// Checks whether a native filesystem recording currently exists at [path].
///
/// Always returns `false` on Web.
Future<bool> diskRecordingFileExists(String path) async => false;

/// Deletes the Web OPFS recording at [path] if present.
Future<bool> deleteOpfsRecordingFile(String path) async {
  if (!isWebOpfsSupported()) return false;
  final segments = _strictOpfsSegments(path);
  try {
    final resolved = await _resolveParentDir(segments, createDirs: false);
    await resolved.parent.removeEntry(resolved.leaf).toDart;
    MapLogger.debug('Deleted OPFS recording file "$path".');
    return true;
  } catch (e) {
    final lower = e.toString().toLowerCase();
    if (lower.contains('notfounderror')) return false;
    _rethrowOpfsError(e, path);
  }
}

/// Deletes the native filesystem recording at [path] if present.
///
/// Always returns `false` on Web.
Future<bool> deleteDiskRecordingFile(String path) async => false;

/// Saves a completed recording from [memoryChunks] or OPFS [sourcePath] (when
/// [sourceIsOpfs] is `true`) into the OPFS [destinationPath] and returns the
/// canonical OPFS path.
Future<String> saveRecordingToDestination({
  required String destinationPath,
  required String sourcePath,
  required bool sourceIsOpfs,
  List<Uint8List>? memoryChunks,
}) async {
  final parsed = sanitizeOpfsRecordingPath(destinationPath);
  if (parsed.hadOpfsPrefix && parsed.errorCode != MapResult.errorUnsupported) {
    MapLogger.logRedundantOpfsPrefix(
      destinationPath,
      canonicalPath: parsed.hasError ? null : parsed.canonicalPath,
    );
  }
  if (parsed.hasError) {
    MapLogger.error(
      'Invalid OPFS destination path "$destinationPath": ${parsed.errorMessage}',
    );
    throw MiniaudioPlayerException(
      parsed.errorMessage ??
          'Invalid OPFS destination path "$destinationPath".',
      errorCode: parsed.errorCode ?? MapResult.errorInvalidArgs,
    );
  }
  final canonicalDest = parsed.canonicalPath!;
  if (!isWebOpfsSupported()) {
    MapLogger.error(
      'OPFS unavailable while saving recording to "$canonicalDest".',
    );
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
    MapLogger.error(
      'saveRecordingToDestination("$canonicalDest") failed: no source OPFS path or in-memory buffer available.',
    );
    throw const MiniaudioPlayerException(
      'Cannot save recording: no source OPFS path or in-memory buffer available.',
      errorCode: MapResult.errorInvalidState,
    );
  }

  final destHandle = await _resolveOpfsFileHandle(canonicalDest, create: true);
  try {
    final writableFn =
        (destHandle as JSObject).getProperty('createWritable'.toJS);
    if (!writableFn.typeofEquals('function')) {
      MapLogger.error(
        'OPFS createWritable is unsupported in this browser for "$canonicalDest".',
      );
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
    } catch (e) {
      MapLogger.warn(
        'OPFS write failed for "$canonicalDest", closing writable stream: $e',
      );
      try {
        await writable.close().toDart;
      } catch (closeErr) {
        MapLogger.debug(
          'Ignoring error while closing failed OPFS writable stream for "$canonicalDest": $closeErr',
        );
      }
      rethrow;
    }
    MapLogger.info(
      'Saved ${payload.length} bytes to OPFS destination "$canonicalDest".',
    );
    return canonicalDest;
  } catch (e) {
    _rethrowOpfsError(e, canonicalDest);
  }
}
