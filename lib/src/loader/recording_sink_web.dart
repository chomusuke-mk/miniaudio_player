import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import '../api/recording_byte_buffer.dart';
import 'recording_sink_stub.dart';

export 'recording_sink_stub.dart' show WebOpfsRecordingSession;

@JS('Blob')
extension type _JSBlob._(JSObject _) implements JSObject {
  external factory _JSBlob(JSArray<JSAny> parts, _JSBlobOptions options);
}

extension type _JSBlobOptions._(JSObject _) implements JSObject {
  external factory _JSBlobOptions({String type});
}

@JS('URL.createObjectURL')
external String _createObjectUrl(_JSBlob blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(String url);

@JS('Worker')
extension type _JSWorker._(JSObject _) implements JSObject {
  external factory _JSWorker(String scriptUrl);
  external set onmessage(JSFunction? fn);
  external set onerror(JSFunction? fn);
  external void postMessage(JSAny? message, [JSArray<JSAny>? transfer]);
  external void terminate();
}

@JS('eval')
external JSAny? _jsEval(String code);

const String _opfsWorkerSource = r'''
let accessHandle = null;
let writable = null;
let cursor = 0;

self.onmessage = async (ev) => {
  const msg = ev.data || {};
  const id = msg.id;
  try {
    if (msg.cmd === 'open') {
      if (!navigator.storage || typeof navigator.storage.getDirectory !== 'function') {
        throw { code: -9, message: 'Origin Private File System (navigator.storage.getDirectory) is unavailable in this browser context. Pass buffer: MemoryRecordingBuffer() instead.' };
      }
      let dir = await navigator.storage.getDirectory();
      const dirs = Array.isArray(msg.dirs)
          ? msg.dirs
          : (msg.dirPath ? String(msg.dirPath).split('/').filter(Boolean) : []);
      for (const seg of dirs) {
        dir = await dir.getDirectoryHandle(seg, { create: true });
      }
      const handle = await dir.getFileHandle(msg.fileName, { create: true });
      if (typeof handle.createSyncAccessHandle === 'function') {
        accessHandle = await handle.createSyncAccessHandle();
        accessHandle.truncate(0);
      } else if (typeof handle.createWritable === 'function') {
        writable = await handle.createWritable({ keepExistingData: false });
      } else {
        throw { code: -9, message: 'OPFS file writing APIs are unsupported in this browser. Pass buffer: MemoryRecordingBuffer() instead.' };
      }
      cursor = 0;
      self.postMessage({ id, ok: true });
      return;
    }

    if (msg.cmd === 'write') {
      const data = new Uint8Array(msg.bytes);
      if (accessHandle) {
        const written = accessHandle.write(data, { at: cursor });
        cursor += written;
      } else if (writable) {
        await writable.seek(cursor);
        await writable.write(data);
        cursor += data.byteLength;
      } else {
        throw { code: -6, message: 'OPFS handle is closed' };
      }
      self.postMessage({ id, ok: true });
      return;
    }

    if (msg.cmd === 'writeAt') {
      const data = new Uint8Array(msg.bytes);
      const at = msg.offset >>> 0;
      if (accessHandle) {
        accessHandle.write(data, { at });
        const end = at + data.byteLength;
        if (end > cursor) cursor = end;
      } else if (writable) {
        await writable.seek(at);
        await writable.write(data);
        const end = at + data.byteLength;
        if (end > cursor) cursor = end;
      } else {
        throw { code: -6, message: 'OPFS handle is closed' };
      }
      self.postMessage({ id, ok: true });
      return;
    }

    if (msg.cmd === 'flush') {
      if (accessHandle) {
        accessHandle.flush();
      }
      self.postMessage({ id, ok: true });
      return;
    }

    if (msg.cmd === 'close') {
      let outBuf = null;
      if (accessHandle) {
        accessHandle.flush();
        const size = accessHandle.getSize();
        const tmp = new Uint8Array(size);
        let offset = 0;
        while (offset < size) {
          const n = accessHandle.read(tmp.subarray(offset), { at: offset });
          if (n <= 0) break;
          offset += n;
        }
        accessHandle.close();
        accessHandle = null;
        outBuf = tmp.buffer;
      } else if (writable) {
        await writable.close();
        writable = null;
      }
      if (outBuf) {
        self.postMessage({ id, ok: true, buffer: outBuf }, [outBuf]);
      } else {
        self.postMessage({ id, ok: true, buffer: null });
      }
      return;
    }

    throw { code: -2, message: 'Unknown OPFS worker command: ' + msg.cmd };
  } catch (err) {
    const code = (err && typeof err.code === 'number') ? err.code : -1;
    const message = (err && err.message) ? String(err.message) : String(err);
    self.postMessage({ id, ok: false, code, message });
  }
};
''';

bool _isOpfsSupportedPrecheck() {
  try {
    final res = _jsEval(
      'Boolean(typeof Worker !== "undefined" && typeof URL !== "undefined" && typeof Blob !== "undefined" && typeof navigator !== "undefined" && navigator.storage && typeof navigator.storage.getDirectory === "function")',
    );
    return (res as JSBoolean?)?.toDart ?? false;
  } catch (_) {
    return false;
  }
}

List<String> _parseOpfsSegments(String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    throw const MiniaudioPlayerException(
      'OPFS recording path cannot be empty.',
      errorCode: MapResult.errorInvalidArgs,
    );
  }
  if (trimmed.contains('://') || trimmed.toLowerCase().startsWith('package:')) {
    throw MiniaudioPlayerException(
      'Unsupported URI scheme "$rawPath" on Web. Use a relative OPFS path (e.g. "recordings/out.wav") or pass buffer: MemoryRecordingBuffer().',
      errorCode: MapResult.errorUnsupported,
    );
  }
  final segments = trimmed
      .replaceAll('\\', '/')
      .split('/')
      .where((s) => s.isNotEmpty && s != '.')
      .toList(growable: false);
  if (segments.isEmpty || segments.any((s) => s == '..')) {
    throw MiniaudioPlayerException(
      'Invalid OPFS recording path "$rawPath".',
      errorCode: MapResult.errorInvalidArgs,
    );
  }
  return segments;
}

extension type _WorkerMsg._(JSObject _) implements JSObject {
  external int get id;
  external bool get ok;
  external int? get code;
  external String? get message;
  external JSArrayBuffer? get buffer;
}

extension type _OpfsReq._(JSObject _) implements JSObject {
  external factory _OpfsReq({
    required int id,
    required String cmd,
    String? dirPath,
    String? fileName,
    JSArrayBuffer? bytes,
    int? offset,
  });

  external int get id;
}

/// Allocates a plain JavaScript 1-element array (`new Array(1)`) without Dart
/// `List` expando metadata (e.g. `fixed$length = Array` in DDC) that triggers
/// `DataCloneError` across `Worker.postMessage`.
JSArray<JSAny> _singleJsArray(JSAny item) =>
    JSArray<JSAny>.withLength(1)..[0] = item;

final class _OpfsBuffer implements RecordingByteBuffer, WebOpfsRecordingSession {
  @override
  final String normalizedPath;
  final _JSWorker _worker;
  final String _blobUrlWorker;
  final Map<int, Completer<_WorkerMsg>> _pending = {};

  int _nextMsgId = 1;
  int _length = 0;
  bool _closed = false;
  Uri? _finalBlobUri;

  _OpfsBuffer._({
    required this.normalizedPath,
    required _JSWorker worker,
    required String workerBlobUrl,
  })  : _worker = worker,
        _blobUrlWorker = workerBlobUrl {
    _worker.onmessage = ((JSAny ev) {
      final data = (_jsGetProp(ev, 'data') as _WorkerMsg?);
      if (data == null) return;
      final completer = _pending.remove(data.id);
      if (completer == null || completer.isCompleted) return;
      if (data.ok) {
        completer.complete(data);
      } else {
        completer.completeError(
          MiniaudioPlayerException(
            data.message ?? 'OPFS recording operation failed',
            errorCode: data.code ?? MapResult.errorGeneric,
          ),
        );
      }
    }).toJS;
    _worker.onerror = ((JSAny ev) {
      final err = MiniaudioPlayerException(
        'OPFS worker error: $ev',
        errorCode: MapResult.errorGeneric,
      );
      for (final c in _pending.values.toList(growable: false)) {
        if (!c.isCompleted) c.completeError(err);
      }
      _pending.clear();
    }).toJS;
  }

  @override
  String? get path => normalizedPath;

  @override
  int get lengthInBytes => _length;

  @override
  RecordingByteBuffer get buffer => this;

  Future<_WorkerMsg> _rpc(_OpfsReq req, [JSArray<JSAny>? transfer]) {
    final c = Completer<_WorkerMsg>();
    _pending[req.id] = c;
    if (transfer != null) {
      _worker.postMessage(req, transfer);
    } else {
      _worker.postMessage(req);
    }
    return c.future;
  }

  Future<void> _open(List<String> dirs, String fileName) async {
    await _rpc(
      _OpfsReq(
        id: _nextMsgId++,
        cmd: 'open',
        dirPath: dirs.join('/'),
        fileName: fileName,
      ),
    );
  }

  @override
  Future<void> write(Uint8List bytes) async {
    if (bytes.isEmpty) return;
    final copy = Uint8List.fromList(bytes);
    final ab = copy.buffer.toJS;
    await _rpc(
      _OpfsReq(
        id: _nextMsgId++,
        cmd: 'write',
        bytes: ab,
      ),
      _singleJsArray(ab),
    );
    _length += bytes.length;
  }

  @override
  Future<void> writeAt(int offset, Uint8List bytes) async {
    if (offset < 0) {
      throw RangeError.value(offset, 'offset', 'Offset cannot be negative');
    }
    if (bytes.isEmpty) return;
    final copy = Uint8List.fromList(bytes);
    final ab = copy.buffer.toJS;
    await _rpc(
      _OpfsReq(
        id: _nextMsgId++,
        cmd: 'writeAt',
        bytes: ab,
        offset: offset,
      ),
      _singleJsArray(ab),
    );
    final end = offset + bytes.length;
    if (end > _length) {
      _length = end;
    }
  }

  @override
  Future<void> flush() async {
    if (_closed) return;
    await _rpc(_OpfsReq(id: _nextMsgId++, cmd: 'flush'));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      final msg = await _rpc(_OpfsReq(id: _nextMsgId++, cmd: 'close'));
      final ab = msg.buffer;
      if (ab != null) {
        final blob = _JSBlob(
          _singleJsArray(ab),
          _JSBlobOptions(type: 'audio/wav'),
        );
        _finalBlobUri = Uri.parse(_createObjectUrl(blob));
      }
    } finally {
      try {
        _worker.terminate();
      } catch (_) {}
      try {
        _revokeObjectUrl(_blobUrlWorker);
      } catch (_) {}
    }
  }

  @override
  Future<Uri?> finalizeBlobUri() async => _finalBlobUri;
}

@JS('Reflect.get')
external JSAny? _jsGetProp(JSAny target, String key);

bool _opfsWarningEmitted = false;

Future<WebOpfsRecordingSession> openWebOpfsRecordingSession(String path) async {
  final segments = _parseOpfsSegments(path);
  final normalized = segments.join('/');

  if (!_isOpfsSupportedPrecheck()) {
    throw const MiniaudioPlayerException(
      'Web string-path recording requires Origin Private File System (OPFS), '
      'which is unavailable in this browser or context. Pass a '
      'RecordingByteBuffer (e.g. buffer: MemoryRecordingBuffer()) instead.',
      errorCode: MapResult.errorUnsupported,
    );
  }

  if (!_opfsWarningEmitted) {
    _opfsWarningEmitted = true;
    MapLogger.warnImportant(
      'Recording on Web with a string path uses browser Origin Private File System '
      '(OPFS: "$normalized"). Some browsers or non-secure contexts may restrict '
      'OPFS access; pass `buffer: MemoryRecordingBuffer()` (or a custom `implements RecordingByteBuffer`) for guaranteed cross-browser in-memory capture.',
    );
  }

  final workerBlob = _JSBlob(
    _singleJsArray(_opfsWorkerSource.toJS),
    _JSBlobOptions(type: 'application/javascript'),
  );
  final workerUrl = _createObjectUrl(workerBlob);
  final worker = _JSWorker(workerUrl);

  final session = _OpfsBuffer._(
    normalizedPath: normalized,
    worker: worker,
    workerBlobUrl: workerUrl,
  );
  final dirs = segments.length > 1
      ? segments.sublist(0, segments.length - 1)
      : const <String>[];
  final fileName = segments.last;

  try {
    await session._open(dirs, fileName);
  } catch (e) {
    try {
      worker.terminate();
    } catch (_) {}
    try {
      _revokeObjectUrl(workerUrl);
    } catch (_) {}
    rethrow;
  }

  return session;
}

Uri? createWavBlobUriFromBytes(Uint8List wavBytes) {
  if (wavBytes.isEmpty) return null;
  final copy = Uint8List.fromList(wavBytes);
  final blob = _JSBlob(
    _singleJsArray(copy.buffer.toJS),
    _JSBlobOptions(type: 'audio/wav'),
  );
  return Uri.parse(_createObjectUrl(blob));
}

void revokeRecordingBlobUri(Uri? uri) {
  if (uri != null && uri.scheme == 'blob') {
    try {
      _revokeObjectUrl(uri.toString());
    } catch (_) {}
  }
}

bool isWebOpfsEnvironment() => true;
