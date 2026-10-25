import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

void allowHttpInTests() {
  HttpOverrides.global = null;
}

bool isFsEntity(dynamic source) => source is FileSystemEntity;

String? getFsPath(dynamic source) {
  if (source is FileSystemEntity) return source.path;
  return null;
}

bool checkFileExists(String path) {
  return File(path).existsSync();
}

/// Verifies whether [path] exists as a regular file and can be directly opened
/// for reading by the current process (testing SELinux / Scoped Storage permissions).
bool isDirectlyReadableRegularFile(String path) {
  if (path.isEmpty) return false;
  try {
    final type = FileSystemEntity.typeSync(path, followLinks: true);
    if (type != FileSystemEntityType.file) return false;
    final raf = File(path).openSync(mode: FileMode.read);
    try {
      return true;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Reads the symbolic link target of `/proc/self/fd/<fd>` on Linux/Android.
///
/// Uses `Link.targetSync()` (`readlink`) first so special kernel dentries
/// (`pipe:[...]`, `socket:[...]`, `anon_inode:[...]`, `... (deleted)`, and
/// internal FUSE mounts like `/mnt/user/0/emulated/0/...`) are preserved even
/// when `realpath()` (`resolveSymbolicLinksSync()`) would fail with `ENOENT` or `EACCES`.
String? readFdSymbolicLink(int fd) {
  if (fd < 0) return null;
  final procPath = '/proc/self/fd/$fd';
  String? rawTarget;
  try {
    final link = Link(procPath);
    rawTarget = link.targetSync();
  } catch (_) {}

  if (rawTarget != null && rawTarget.isNotEmpty) {
    if (rawTarget.startsWith('pipe:') ||
        rawTarget.startsWith('socket:') ||
        rawTarget.startsWith('anon_inode:') ||
        rawTarget.endsWith(' (deleted)')) {
      return rawTarget;
    }
    try {
      final resolved = File(procPath).resolveSymbolicLinksSync();
      if (resolved.isNotEmpty) {
        return resolved;
      }
    } catch (_) {}
    return rawTarget;
  }

  try {
    return File(procPath).resolveSymbolicLinksSync();
  } catch (_) {
    return null;
  }
}

// ============================================================================
// POSIX File Descriptor Primitives (Linux / Android / macOS / iOS)
// ============================================================================

typedef _CloseNative = Int32 Function(Int32 fd);
typedef _CloseDart = int Function(int fd);

typedef _ReadNative = IntPtr Function(
  Int32 fd,
  Pointer<Uint8> buf,
  IntPtr count,
);
typedef _ReadDart = int Function(int fd, Pointer<Uint8> buf, int count);

typedef _PreadNative = IntPtr Function(
  Int32 fd,
  Pointer<Uint8> buf,
  IntPtr count,
  Int64 offset,
);
typedef _PreadDart = int Function(
  int fd,
  Pointer<Uint8> buf,
  int count,
  int offset,
);

typedef _LseekNative = Int64 Function(Int32 fd, Int64 offset, Int32 whence);
typedef _LseekDart = int Function(int fd, int offset, int whence);

typedef _OpenNative = Int32 Function(Pointer<Utf8> pathname, Int32 flags);
typedef _OpenDart = int Function(Pointer<Utf8> pathname, int flags);

typedef _DupNative = Int32 Function(Int32 oldfd);
typedef _DupDart = int Function(int oldfd);

typedef _PipeNative = Int32 Function(Pointer<Int32> pipefd);
typedef _PipeDart = int Function(Pointer<Int32> pipefd);

final class _PollFd extends Struct {
  @Int32()
  external int fd;

  @Int16()
  external int events;

  @Int16()
  external int revents;
}

typedef _PollNative = Int32 Function(
  Pointer<_PollFd> fds,
  Uint64 nfds,
  Int32 timeout,
);
typedef _PollDart = int Function(
  Pointer<_PollFd> fds,
  int nfds,
  int timeout,
);

bool _posixInitialized = false;
_CloseDart? _posixClose;
_ReadDart? _posixRead;
_ReadDart? _posixWrite;
_PreadDart? _posixPread;
_LseekDart? _posixLseek;
_OpenDart? _posixOpen;
_DupDart? _posixDup;
_PipeDart? _posixPipe;
_PollDart? _posixPoll;

void _ensurePosixLoaded() {
  if (_posixInitialized) return;
  _posixInitialized = true;
  if (Platform.isWindows) return;
  try {
    final lib = DynamicLibrary.process();
    try {
      _posixClose = lib.lookupFunction<_CloseNative, _CloseDart>('close');
    } catch (_) {}
    try {
      _posixRead = lib.lookupFunction<_ReadNative, _ReadDart>('read');
    } catch (_) {}
    try {
      _posixWrite = lib.lookupFunction<_ReadNative, _ReadDart>('write');
    } catch (_) {}
    try {
      _posixPread = lib.lookupFunction<_PreadNative, _PreadDart>('pread64');
    } catch (_) {
      try {
        _posixPread = lib.lookupFunction<_PreadNative, _PreadDart>('pread');
      } catch (_) {}
    }
    try {
      _posixLseek = lib.lookupFunction<_LseekNative, _LseekDart>('lseek64');
    } catch (_) {
      try {
        _posixLseek = lib.lookupFunction<_LseekNative, _LseekDart>('lseek');
      } catch (_) {}
    }
    try {
      _posixOpen = lib.lookupFunction<_OpenNative, _OpenDart>('open');
    } catch (_) {}
    try {
      _posixDup = lib.lookupFunction<_DupNative, _DupDart>('dup');
    } catch (_) {}
    try {
      _posixPipe = lib.lookupFunction<_PipeNative, _PipeDart>('pipe');
    } catch (_) {}
    try {
      _posixPoll = lib.lookupFunction<_PollNative, _PollDart>('poll');
    } catch (_) {}
  } catch (_) {}
}

/// Opens [path] in read-only mode (`O_RDONLY`) and returns its native file descriptor,
/// or `-1` on failure.
int openNativeFd(String path) {
  _ensurePosixLoaded();
  final fn = _posixOpen;
  if (fn == null || path.isEmpty) return -1;
  final cPath = path.toNativeUtf8();
  try {
    return fn(cPath, 0); // O_RDONLY = 0
  } finally {
    malloc.free(cPath);
  }
}

/// Creates an anonymous POSIX pipe pair `(readFd, writeFd)`, or `null` if unsupported.
(int, int)? createNativePipe() {
  _ensurePosixLoaded();
  final fn = _posixPipe;
  if (fn == null) return null;
  final fds = calloc<Int32>(2);
  try {
    final res = fn(fds);
    if (res != 0) return null;
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

/// Writes [bytes] into native file descriptor [fd]. Returns number of bytes written or `-1`.
int writeNativeFd(int fd, Uint8List bytes) {
  _ensurePosixLoaded();
  final fn = _posixWrite;
  if (fn == null || fd < 0) return -1;
  if (bytes.isEmpty) return 0;
  final ptr = malloc.allocate<Uint8>(bytes.length);
  try {
    ptr.asTypedList(bytes.length).setAll(0, bytes);
    int totalWritten = 0;
    while (totalWritten < bytes.length) {
      final n = fn(
        fd,
        Pointer<Uint8>.fromAddress(ptr.address + totalWritten),
        bytes.length - totalWritten,
      );
      if (n <= 0) {
        return totalWritten > 0 ? totalWritten : -1;
      }
      totalWritten += n;
    }
    return totalWritten;
  } finally {
    malloc.free(ptr);
  }
}

/// Duplicates native file descriptor [fd] via `dup(fd)`, or returns `-1` on failure.
int dupNativeFd(int fd) {
  _ensurePosixLoaded();
  final fn = _posixDup;
  if (fn == null || fd < 0) return -1;
  return fn(fd);
}

/// Closes native file descriptor [fd] via POSIX `close(fd)`.
bool closeNativeFdSync(int fd) {
  _ensurePosixLoaded();
  final fn = _posixClose;
  if (fn == null || fd < 0) return false;
  return fn(fd) == 0;
}

/// Returns `true` if [fd] supports random-access seeking (`lseek(fd, 0, SEEK_CUR) >= 0`).
bool isNativeFdSeekable(int fd) {
  if (fd < 0) return false;
  _ensurePosixLoaded();
  final fn = _posixLseek;
  if (fn != null) {
    final pos = fn(fd, 0, 1); // SEEK_CUR = 1
    return pos >= 0;
  }
  try {
    final raf = File('/proc/self/fd/$fd').openSync(mode: FileMode.read);
    try {
      raf.positionSync();
      return true;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return false;
  }
}

/// Returns the total byte length of the inode backing [fd], or `-1` if unknown / non-seekable.
int getNativeFdLength(int fd) {
  if (fd < 0) return -1;
  _ensurePosixLoaded();
  final lseekFn = _posixLseek;
  if (lseekFn != null) {
    final cur = lseekFn(fd, 0, 1); // SEEK_CUR = 1
    if (cur >= 0) {
      final end = lseekFn(fd, 0, 2); // SEEK_END = 2
      lseekFn(fd, cur, 0); // SEEK_SET = 0 (restore cursor)
      if (end >= 0) return end;
    }
  }
  try {
    return File('/proc/self/fd/$fd').lengthSync();
  } catch (_) {
    return -1;
  }
}

/// Atomically reads up to [length] bytes at [offset] from [fd] via POSIX `pread`
/// without mutating the kernel `f_pos` cursor.
Uint8List? preadNativeFd(int fd, int offset, int length) {
  if (fd < 0 || offset < 0 || length <= 0) return null;
  _ensurePosixLoaded();
  final fn = _posixPread;
  if (fn != null) {
    final ptr = malloc.allocate<Uint8>(length);
    try {
      int totalRead = 0;
      while (totalRead < length) {
        final n = fn(
          fd,
          Pointer<Uint8>.fromAddress(ptr.address + totalRead),
          length - totalRead,
          offset + totalRead,
        );
        if (n < 0) {
          return totalRead > 0
              ? Uint8List.fromList(ptr.asTypedList(totalRead))
              : null;
        }
        if (n == 0) break; // EOF
        totalRead += n;
      }
      return Uint8List.fromList(ptr.asTypedList(totalRead));
    } finally {
      malloc.free(ptr);
    }
  }
  // Fallback via /proc/self/fd/<fd>
  try {
    final raf = File('/proc/self/fd/$fd').openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(offset);
      return raf.readSync(length);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// Returns `true` if [fd] is ready for non-blocking `read()` (data available, EOF, or error).
/// Returns `false` if [fd] is a pipe/socket that currently has no bytes ready and would block.
bool isNativeFdReadyToRead(int fd) {
  if (fd < 0) return true;
  _ensurePosixLoaded();
  final pollFn = _posixPoll;
  if (pollFn == null) return true;
  final pfd = calloc<_PollFd>();
  try {
    pfd.ref.fd = fd;
    pfd.ref.events = 0x0001; // POLLIN
    pfd.ref.revents = 0;
    final res = pollFn(pfd, 1, 0);
    return res != 0;
  } finally {
    calloc.free(pfd);
  }
}

/// Sequentially reads up to [maxBytes] from [fd] via POSIX `read(fd, buf, maxBytes)`
/// without calling `lseek` or `setPosition` (safe for `pipe:`, `socket:`, `anon_inode:`).
Uint8List? readSequentialNativeFd(int fd, int maxBytes) {
  if (fd < 0 || maxBytes <= 0) return null;
  _ensurePosixLoaded();
  final fn = _posixRead;
  if (fn == null) return null;
  final ptr = malloc.allocate<Uint8>(maxBytes);
  try {
    final n = fn(fd, ptr, maxBytes);
    if (n < 0) return null;
    if (n == 0) return Uint8List(0);
    return Uint8List.fromList(ptr.asTypedList(n));
  } finally {
    malloc.free(ptr);
  }
}

Uint8List? readBytesFromFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  try {
    return file.readAsBytesSync();
  } catch (_) {
    return null;
  }
}

(Uint8List, int) readFileHeaderAndLength(String path, int maxHeaderBytes) {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Audio file not found at path', path);
  }
  final raf = file.openSync(mode: FileMode.read);
  try {
    final len = raf.lengthSync();
    final toRead = len < maxHeaderBytes ? len : maxHeaderBytes;
    final header = toRead > 0 ? raf.readSync(toRead) : Uint8List(0);
    return (header, len);
  } finally {
    raf.closeSync();
  }
}

Future<Uint8List> readFileBytes(String path) async {
  return await File(path).readAsBytes();
}

Future<int> getFileLength(String path) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Audio file not found at path', path);
  }
  if (FileSystemEntity.isDirectorySync(path)) {
    throw FileSystemException('Path is a directory, not an audio file', path);
  }
  return file.lengthSync();
}

Stream<Uint8List> openFileStream(String path, {int offset = 0, int? length}) {
  final file = File(path);
  final int? end = length != null ? offset + length : null;
  return file.openRead(offset, end).map(
        (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
      );
}

Future<Uint8List> readFileRange(String path, int offset, int length) async {
  final file = File(path);
  final raf = await file.open(mode: FileMode.read);
  try {
    await raf.setPosition(offset);
    return await raf.read(length);
  } finally {
    await raf.close();
  }
}

Future<int> rafLength(dynamic handle) async {
  if (handle is RandomAccessFile) return await handle.length();
  return await (handle.length() as FutureOr<int>);
}

Future<void> rafSetPosition(dynamic handle, int offset) async {
  if (handle is RandomAccessFile) {
    await handle.setPosition(offset);
    return;
  }
  await handle.setPosition(offset);
}

Future<Uint8List> rafRead(dynamic handle, int count) async {
  if (handle is RandomAccessFile) return await handle.read(count);
  final res = await handle.read(count);
  return res is Uint8List ? res : Uint8List.fromList(res as List<int>);
}

Future<void> rafClose(dynamic handle) async {
  if (handle is RandomAccessFile) {
    await handle.close();
    return;
  }
  await handle.close();
}
