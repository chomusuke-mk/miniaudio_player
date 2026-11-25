/// Platform-independent audio source URI normalization and OPFS path helpers.
///
/// @docImport '../api/miniaudio_player.dart';
library;

import 'dart:convert' show utf8;
import 'dart:typed_data';

import '../api/logger.dart';
import '../api/player_exception.dart';
import '../loader/custom_byte_provider.dart';

/// Canonical parse outcome for Web OPFS paths without retaining `opfs://` or
/// leading `/`.
class OpfsPathParseResult {
  /// Canonical OPFS path (for example `'temporal/sistema/test/1.wav'` or
  /// `'1.wav'`), or `null` when parsing fails.
  final String? canonicalPath;

  /// Whether an optional `opfs://` prefix was supplied and stripped.
  final bool hadOpfsPrefix;

  /// Optional [MapResult] error code, or `null` on success.
  final int? errorCode;

  /// Human-readable error message paired with [errorCode], or `null` on
  /// success.
  final String? errorMessage;

  /// Creates a successful [OpfsPathParseResult] carrying [canonicalPath] and
  /// whether [hadOpfsPrefix] was present.
  const OpfsPathParseResult.ok(
    this.canonicalPath, {
    required this.hadOpfsPrefix,
  })  : errorCode = null,
        errorMessage = null;

  /// Creates a failed [OpfsPathParseResult] with [errorCode], [errorMessage],
  /// and whether [hadOpfsPrefix] was present.
  const OpfsPathParseResult.err(
    this.errorCode,
    this.errorMessage, {
    this.hadOpfsPrefix = false,
  }) : canonicalPath = null;

  /// Whether parsing failed and produced an [errorCode].
  bool get hasError => errorCode != null;
}

/// Synchronous Dart-side normalization result for an [AudioSource] input.
class NormalizedAudioSource {
  /// Clean source string ready for the native engine, or the canonical
  /// internal key when [resolveInDart] is `true`.
  final String normalizedSource;

  /// Whether the engine must delegate resolution back to Dart before opening
  /// or decoding this source.
  final bool resolveInDart;

  /// Optional immediate validation failure code, such as
  /// [MapResult.errorUnsupported].
  final int? directErrorCode;

  /// Optional descriptive message paired with [directErrorCode].
  final String? directErrorMessage;

  /// Whether a redundant Web `opfs://` prefix was stripped during
  /// normalization.
  final bool strippedOpfsPrefix;

  /// Creates a [NormalizedAudioSource] with [normalizedSource], [resolveInDart],
  /// optional [directErrorCode] and [directErrorMessage], and
  /// [strippedOpfsPrefix].
  const NormalizedAudioSource({
    required this.normalizedSource,
    required this.resolveInDart,
    this.directErrorCode,
    this.directErrorMessage,
    this.strippedOpfsPrefix = false,
  });

  /// Whether synchronous normalization detected a validation error.
  bool get hasError => directErrorCode != null;
}

/// Unified asynchronous resolution outcome produced by Dart for deferred
/// schemes such as `asset://`, `package:`, `content://`, `android.resource://`,
/// `ws://`, and `wss://`.
sealed class DartResolvedSourceResult {
  /// Creates a [DartResolvedSourceResult].
  const DartResolvedSourceResult();
}

/// Resolution result pointing to an ordinary filesystem [path] consumable
/// directly by the native engine.
final class DartResolvedPath extends DartResolvedSourceResult {
  /// Resolved local filesystem path.
  final String path;

  /// Creates a [DartResolvedPath] wrapping [path].
  const DartResolvedPath(this.path);
}

/// Resolution result pointing to an HTTP or asset [url] consumable directly by
/// native or browser streaming.
final class DartResolvedUrl extends DartResolvedSourceResult {
  /// Resolved HTTP or asset URL string.
  final String url;

  /// Creates a [DartResolvedUrl] wrapping [url].
  const DartResolvedUrl(this.url);
}

/// Resolution result carrying a detached POSIX file descriptor [fd] and an
/// optional bounded slice.
final class DartResolvedFd extends DartResolvedSourceResult {
  /// Detached POSIX file descriptor number.
  final int fd;

  /// Starting byte offset within [fd].
  final int offset;

  /// Optional readable byte length from [offset], or `null` when unbounded.
  final int? length;

  /// Optional lowercase container extension hint without a leading dot.
  final String? hintExt;

  /// Creates a [DartResolvedFd] for [fd], starting at [offset] with optional
  /// [length] and [hintExt].
  const DartResolvedFd({
    required this.fd,
    this.offset = 0,
    this.length,
    this.hintExt,
  });
}

/// Resolution result holding full in-memory audio [bytes] owned once and
/// transferred to the engine.
final class DartResolvedBytes extends DartResolvedSourceResult {
  /// Decodable raw audio file bytes.
  final Uint8List bytes;

  /// Optional lowercase container extension hint without a leading dot.
  final String? hintExt;

  /// Creates a [DartResolvedBytes] containing [bytes] and an optional
  /// [hintExt].
  const DartResolvedBytes(this.bytes, {this.hintExt});
}

/// Resolution result wrapping a live pull-based [CustomByteProvider] stream,
/// such as a WebSocket audio stream.
final class DartResolvedCustomStream extends DartResolvedSourceResult {
  /// Internal stream identifier registered with the player engine.
  final int streamId;

  /// Optional lowercase container extension hint without a leading dot.
  final String? hintExt;

  /// Active [CustomByteProvider] supplying stream bytes.
  final CustomByteProvider provider;

  /// Creates a [DartResolvedCustomStream] with [streamId], [provider], and an
  /// optional [hintExt].
  const DartResolvedCustomStream({
    required this.streamId,
    required this.provider,
    this.hintExt,
  });
}

/// Explicit resolution failure carrying a [MapResult] error [code] and
/// human-readable [message].
final class DartResolvedError extends DartResolvedSourceResult {
  /// Numeric [MapResult] error code.
  final int code;

  /// Descriptive failure message.
  final String message;

  /// Creates a [DartResolvedError] with [code] and [message].
  const DartResolvedError(this.code, this.message);
}

/// Network file-transfer URI schemes rejected with
/// [MapResult.errorUnsupported].
const Set<String> _unsupportedNetworkSchemes = <String>{
  'ftp',
  'ftps',
  'sftp',
};

/// Real-time media transport URI schemes rejected with
/// [MapResult.errorUnsupported].
const Set<String> _unsupportedStreamingSchemes = <String>{
  'rtsp',
  'rtsps',
  'rtmp',
  'rtmps',
};

/// Apple media library URI schemes that require native export before
/// playback.
const Set<String> _unsupportedAppleMediaSchemes = <String>{
  'ipod-library',
  'phasset',
};

/// Returns the lowercase RFC 3986 URI scheme of [raw] if present, or `null`
/// for plain paths and Windows drive letters such as `C:\song.mp3` or
/// `C:/song.mp3`.
String? extractUriScheme(String raw) {
  final input = raw.trimLeft();
  if (input.isEmpty) return null;

  // Ignore Windows drive letters (e.g. "C:\..." or "C:/...").
  if (input.length >= 2 &&
      _isAsciiAlpha(input.codeUnitAt(0)) &&
      input.codeUnitAt(1) == 0x3A /* ':' */ &&
      (input.length == 2 ||
          input.codeUnitAt(2) == 0x2F /* '/' */ ||
          input.codeUnitAt(2) == 0x5C /* '\\' */)) {
    return null;
  }

  final colonIdx = input.indexOf(':');
  if (colonIdx <= 0) return null;

  if (!_isAsciiAlpha(input.codeUnitAt(0))) return null;
  for (var i = 1; i < colonIdx; i++) {
    final c = input.codeUnitAt(i);
    if (!(_isAsciiAlpha(c) ||
        _isAsciiDigit(c) ||
        c == 0x2B /* '+' */ ||
        c == 0x2D /* '-' */ ||
        c == 0x2E /* '.' */)) {
      return null;
    }
  }
  return input.substring(0, colonIdx).toLowerCase();
}

/// Returns whether UTF-16 code unit [c] is an ASCII letter (`A`–`Z` or
/// `a`–`z`).
bool _isAsciiAlpha(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

/// Returns whether UTF-16 code unit [c] is an ASCII decimal digit (`0`–`9`).
bool _isAsciiDigit(int c) => c >= 0x30 && c <= 0x39;

/// Strips the leading `scheme://` or `scheme:` prefix and any leading slashes
/// from [rawUri] to obtain a normalized relative key.
String extractRelativeAssetKey(String rawUri) {
  final colonIdx = rawUri.indexOf(':');
  final afterScheme = colonIdx >= 0 ? rawUri.substring(colonIdx + 1) : rawUri;
  return afterScheme.replaceFirst(RegExp(r'^/+'), '');
}

/// Extracts a lowercase file extension hint without a leading dot from [raw],
/// or `null` if none is present.
///
/// Strips query strings and fragments for network URLs, and strips query
/// strings for Android `content://` and `android.resource://` URIs while
/// preserving `#` in local filenames.
String? extractExtensionHintFromSource(String raw) {
  final scheme = extractUriScheme(raw);
  final isNetworkUrl = scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'ws' ||
      scheme == 'wss';
  var clean = raw;
  if (isNetworkUrl) {
    clean = clean.split('#').first.split('?').first;
  } else if (scheme == 'content' || scheme == 'android.resource') {
    clean = clean.split('?').first;
  }
  final slashIdx = clean.lastIndexOf('/');
  final backslashIdx = clean.lastIndexOf('\\');
  final sep = slashIdx > backslashIdx ? slashIdx : backslashIdx;
  final fileName = sep >= 0 ? clean.substring(sep + 1) : clean;
  final dotIdx = fileName.lastIndexOf('.');
  if (dotIdx <= 0 || dotIdx + 1 >= fileName.length) return null;
  final ext = fileName.substring(dotIdx + 1).trim().toLowerCase();
  return ext.isEmpty ? null : ext;
}

/// Encodes a Flutter [assetKey] (`assets/...` or `packages/<pkg>/...`) to the
/// HTTP URL served by Flutter Web relative to [baseUri] (defaulting to
/// [Uri.base]).
///
/// Built Web bundles (`flutter build web`) and `flutter run` asset servers
/// expect double URI encoding when [doubleEncode] is `true`.
String buildFlutterWebAssetUrl(
  String assetKey, {
  required bool doubleEncode,
  Uri? baseUri,
}) {
  final cleanKey = assetKey.replaceFirst(RegExp(r'^/+'), '');
  final segments = cleanKey.split('/').where((s) => s.isNotEmpty).toList();
  final onceEncoded = Uri(pathSegments: segments).path;
  final relPath = doubleEncode
      ? Uri.encodeFull('assets/$onceEncoded')
      : 'assets/$onceEncoded';
  return (baseUri ?? Uri.base).resolve(relPath).toString();
}

/// Resolves a `file://` [rawUri] into a clean local filesystem path using
/// RFC 8089 rules for Windows when [isWindows] is `true` or POSIX otherwise.
///
/// Unencoded `#` characters in naive string concatenations (`'file://' + path`)
/// are escaped before parsing so filenames containing `#` are not truncated.
/// Throws a [FormatException] for malformed or empty `file://` URIs, or an
/// [UnsupportedError] for non-`localhost` authorities on non-Windows targets.
String resolveFileUriToPath(String rawUri, {required bool isWindows}) {
  final trimmed = rawUri.trim();
  // Preserve literal '#' as part of the filename instead of a URI fragment.
  final sanitized = trimmed.replaceAll('#', '%23');
  final parsed = Uri.tryParse(sanitized);
  if (parsed == null || parsed.scheme.toLowerCase() != 'file') {
    throw FormatException(
      'Malformed file URI "$rawUri". Expected RFC 8089 format such as '
      '"file:///path/to/audio.mp3" or "file:///C:/path/to/audio.mp3".',
    );
  }

  final host = parsed.host;
  if (host.isNotEmpty && host.toLowerCase() != 'localhost') {
    if (isWindows) {
      final uncTail = Uri.decodeComponent(parsed.path).replaceAll('/', '\\');
      return '\\\\$host$uncTail';
    }
    throw UnsupportedError(
      'Unsupported file URI authority "$host" in "$rawUri". Local paths '
      'must use "file:///..." or "file://localhost/...".',
    );
  }

  // Normalize file://localhost/... to empty authority for Uri.toFilePath.
  final normalizedForPath = host.isNotEmpty ? parsed.replace(host: '') : parsed;
  final filePath = normalizedForPath.toFilePath(windows: isWindows);
  if (filePath.isEmpty) {
    throw FormatException('Empty path in file URI "$rawUri".');
  }
  return filePath;
}

/// Windows reserved DOS device names forbidden as OPFS path segment stems.
const Set<String> _windowsReservedDeviceNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Maximum UTF-8 byte length allowed for a single OPFS filename segment.
const int _opfsMaxSegmentUtf8Bytes = 255;

/// Returns whether UTF-16 code unit [c] is disallowed in OPFS path segments.
bool _isOpfsForbiddenCharCode(int c) {
  if (c < 0x20 || c == 0x7F) return true;
  return c == 0x3C /* '<' */ ||
      c == 0x3E /* '>' */ ||
      c == 0x3A /* ':' */ ||
      c == 0x22 /* '"' */ ||
      c == 0x7C /* '|' */ ||
      c == 0x3F /* '?' */ ||
      c == 0x2A /* '*' */ ||
      c == 0x5C /* '\\' */;
}

/// Returns whether [segment] matches a Windows reserved device name stem.
bool _isWindowsReservedSegment(String segment) {
  final dotIdx = segment.indexOf('.');
  final stem =
      (dotIdx >= 0 ? segment.substring(0, dotIdx) : segment).toUpperCase();
  return _windowsReservedDeviceNames.contains(stem);
}

/// Returns the UTF-8 byte length required to encode Unicode scalar [rune].
int _runeUtf8ByteLength(int rune) {
  if (rune <= 0x7F) return 1;
  if (rune <= 0x7FF) return 2;
  if (rune <= 0xFFFF) return 3;
  return 4;
}

/// Truncates [text] along Unicode rune boundaries so its UTF-8 encoding does
/// not exceed [maxBytes].
String _truncateUtf8ToBytes(String text, int maxBytes) {
  if (maxBytes <= 0 || text.isEmpty) return '';
  final sb = StringBuffer();
  var used = 0;
  for (final rune in text.runes) {
    final w = _runeUtf8ByteLength(rune);
    if (used + w > maxBytes) break;
    sb.writeCharCode(rune);
    used += w;
  }
  return sb.toString();
}

/// Sanitizes a single [rawSegment] for OPFS recording creation, preserving the
/// file extension when [isLeaf] is `true` and truncating within 255 UTF-8
/// bytes.
String _sanitizeOpfsSegment(String rawSegment, {required bool isLeaf}) {
  final sb = StringBuffer();
  for (final codeUnit in rawSegment.codeUnits) {
    if (_isOpfsForbiddenCharCode(codeUnit)) {
      sb.write('_');
    } else {
      sb.writeCharCode(codeUnit);
    }
  }
  var cleaned = sb.toString().replaceFirst(RegExp(r'[. ]+$'), '');
  if (cleaned.isEmpty) return '';

  if (_isWindowsReservedSegment(cleaned)) {
    cleaned = '_$cleaned';
  }

  if (utf8.encode(cleaned).length <= _opfsMaxSegmentUtf8Bytes) {
    return cleaned;
  }

  if (isLeaf) {
    final lastDot = cleaned.lastIndexOf('.');
    if (lastDot > 0) {
      final ext = cleaned.substring(lastDot);
      final extBytes = utf8.encode(ext).length;
      if (extBytes > 1 &&
          extBytes <= 32 &&
          extBytes < _opfsMaxSegmentUtf8Bytes) {
        final stemBudget = _opfsMaxSegmentUtf8Bytes - extBytes;
        var stem =
            _truncateUtf8ToBytes(cleaned.substring(0, lastDot), stemBudget)
                .replaceFirst(RegExp(r'[. ]+$'), '');
        if (stem.isEmpty) stem = '_';
        return '$stem$ext';
      }
    }
  }

  return _truncateUtf8ToBytes(cleaned, _opfsMaxSegmentUtf8Bytes)
      .replaceFirst(RegExp(r'[. ]+$'), '');
}

/// Extracts the path body of [rawPath] after an optional `opfs://` prefix,
/// using [contextLabel] in validation error messages.
///
/// Returns a record containing the extracted body, whether an `opfs://` prefix
/// was present, and an optional [OpfsPathParseResult] error when invalid.
({String body, bool hadPrefix, OpfsPathParseResult? error}) _extractOpfsBody(
  String rawPath, {
  required String contextLabel,
}) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) {
    return (
      body: '',
      hadPrefix: false,
      error: OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        '$contextLabel path cannot be empty.',
      ),
    );
  }

  final scheme = extractUriScheme(trimmed);
  if (scheme == null) {
    return (body: trimmed, hadPrefix: false, error: null);
  }
  if (scheme != 'opfs') {
    return (
      body: '',
      hadPrefix: false,
      error: OpfsPathParseResult.err(
        MapResult.errorUnsupported,
        'Unsupported URI scheme "$scheme://" in $contextLabel path "$rawPath".',
      ),
    );
  }
  if (trimmed.length < 7 ||
      trimmed.substring(0, 7).toLowerCase() != 'opfs://') {
    return (
      body: '',
      hadPrefix: true,
      error: OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'Malformed opfs URI "$rawPath". Expected "opfs://<path>" or a plain '
        'relative/absolute path without a URI scheme.',
        hadOpfsPrefix: true,
      ),
    );
  }
  return (body: trimmed.substring(7), hadPrefix: true, error: null);
}

/// Strictly validates a Web OPFS [rawPath] for playback, analysis, and SFX
/// without silently altering invalid segment names.
///
/// Accepts relative or absolute paths (such as `'/temporal/sistema/test/1.wav'`,
/// `'temporal/sistema/test/1.wav'`, or `'1.wav'`) as well as optional `opfs://`
/// prefixes, which are stripped from [OpfsPathParseResult.canonicalPath].
OpfsPathParseResult parseOpfsPathStrict(String rawPath) {
  final extracted = _extractOpfsBody(rawPath, contextLabel: 'OPFS');
  if (extracted.error != null) {
    MapLogger.verbose(
      'OPFS strict validation failed for "$rawPath": '
      '${extracted.error!.errorMessage}',
    );
    return extracted.error!;
  }
  final body = extracted.body;
  final hadOpfsPrefix = extracted.hadPrefix;

  if (body.contains('\\')) {
    MapLogger.verbose(
        'OPFS strict validation rejected backslash in "$rawPath".');
    return OpfsPathParseResult.err(
      MapResult.errorInvalidArgs,
      'Invalid backslash "\\" in OPFS path "$rawPath". Use forward slashes "/".',
      hadOpfsPrefix: hadOpfsPrefix,
    );
  }

  // Strip leading '/' only so '/temporal/sistema/test/1.wav' and
  // 'temporal/sistema/test/1.wav' map to the exact same canonical path.
  final withoutLeading = body.replaceFirst(RegExp(r'^/+'), '');
  if (withoutLeading.isEmpty) {
    return OpfsPathParseResult.err(
      MapResult.errorInvalidArgs,
      'OPFS path "$rawPath" must name a file.',
      hadOpfsPrefix: hadOpfsPrefix,
    );
  }
  if (withoutLeading.endsWith('/')) {
    return OpfsPathParseResult.err(
      MapResult.errorInvalidArgs,
      'OPFS path "$rawPath" cannot end with "/" (missing file name).',
      hadOpfsPrefix: hadOpfsPrefix,
    );
  }

  final segments = withoutLeading.split('/');
  for (final seg in segments) {
    if (seg.isEmpty) {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS path "$rawPath" contains empty "//" path segments.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    if (seg == '.' || seg == '..') {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS path "$rawPath" cannot contain "." or ".." segments.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    for (final unit in seg.codeUnits) {
      if (_isOpfsForbiddenCharCode(unit)) {
        return OpfsPathParseResult.err(
          MapResult.errorInvalidArgs,
          'Invalid character in OPFS segment "$seg" of "$rawPath".',
          hadOpfsPrefix: hadOpfsPrefix,
        );
      }
    }
    if (seg.endsWith('.') || seg.endsWith(' ')) {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS path segment "$seg" in "$rawPath" cannot end with "." or whitespace.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    if (_isWindowsReservedSegment(seg)) {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS path segment "$seg" in "$rawPath" uses a reserved device name.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    if (utf8.encode(seg).length > _opfsMaxSegmentUtf8Bytes) {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS path segment "$seg" in "$rawPath" exceeds 255 UTF-8 bytes.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
  }

  return OpfsPathParseResult.ok(
    segments.join('/'),
    hadOpfsPrefix: hadOpfsPrefix,
  );
}

/// Parses and sanitizes a Web OPFS recording [rawPath] so invalid characters,
/// trailing dots or spaces, and reserved filenames do not fail with browser
/// `InvalidName` errors.
///
/// Rejects empty paths, directory-only trailing slashes, `..` traversal, and
/// non-OPFS URI schemes. Always returns a canonical path without `opfs://` or
/// leading `/`.
OpfsPathParseResult sanitizeOpfsRecordingPath(String rawPath) {
  final extracted = _extractOpfsBody(rawPath, contextLabel: 'OPFS recording');
  if (extracted.error != null) {
    MapLogger.verbose(
      'OPFS recording sanitization failed for "$rawPath": '
      '${extracted.error!.errorMessage}',
    );
    return extracted.error!;
  }
  final body = extracted.body;
  final hadOpfsPrefix = extracted.hadPrefix;

  final slashNormalized = body.replaceAll('\\', '/');
  if (slashNormalized.isEmpty || slashNormalized.endsWith('/')) {
    return OpfsPathParseResult.err(
      MapResult.errorInvalidArgs,
      'OPFS recording path "$rawPath" must specify a file name.',
      hadOpfsPrefix: hadOpfsPrefix,
    );
  }

  final rawParts = slashNormalized.replaceFirst(RegExp(r'^/+'), '').split('/');
  final nonEmptyRaw = <String>[];
  for (final part in rawParts) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'Path traversal ".." is not allowed in OPFS recording path "$rawPath".',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    nonEmptyRaw.add(part);
  }

  if (nonEmptyRaw.isEmpty) {
    return OpfsPathParseResult.err(
      MapResult.errorInvalidArgs,
      'OPFS recording path "$rawPath" does not contain a valid file name.',
      hadOpfsPrefix: hadOpfsPrefix,
    );
  }

  final sanitizedSegments = <String>[];
  for (var i = 0; i < nonEmptyRaw.length; i++) {
    final isLeaf = i + 1 == nonEmptyRaw.length;
    final clean = _sanitizeOpfsSegment(nonEmptyRaw[i], isLeaf: isLeaf);
    if (clean.isEmpty) {
      return OpfsPathParseResult.err(
        MapResult.errorInvalidArgs,
        'OPFS recording segment "${nonEmptyRaw[i]}" in "$rawPath" sanitizes to an empty name.',
        hadOpfsPrefix: hadOpfsPrefix,
      );
    }
    sanitizedSegments.add(clean);
  }

  return OpfsPathParseResult.ok(
    sanitizedSegments.join('/'),
    hadOpfsPrefix: hadOpfsPrefix,
  );
}

/// Synchronously normalizes and validates [rawUri] for the target specified by
/// [isWeb], [isWindows], [isAndroid], [isDebug], and optional [webBaseUri]
/// without blocking I/O.
///
/// The [isDebug] flag is retained for target parity with platform wrappers
/// (Web and native normalization). Returns a [NormalizedAudioSource] indicating
/// whether the source can be handed directly to the engine, requires deferred
/// Dart resolution, or failed synchronous validation.
NormalizedAudioSource normalizeAudioSourceUri(
  String rawUri, {
  required bool isWeb,
  required bool isWindows,
  required bool isAndroid,
  required bool isDebug,
  Uri? webBaseUri,
}) {
  final trimmed = rawUri.trim();
  if (trimmed.isEmpty) {
    MapLogger.verbose('Rejected empty audio source URI.');
    return const NormalizedAudioSource(
      normalizedSource: '',
      resolveInDart: true,
      directErrorCode: MapResult.errorInvalidArgs,
      directErrorMessage: 'Audio source URI/path cannot be empty.',
    );
  }

  final scheme = extractUriScheme(trimmed);
  if (scheme == null) {
    if (isWeb) {
      final parsedOpfs = parseOpfsPathStrict(trimmed);
      if (parsedOpfs.hasError) {
        return NormalizedAudioSource(
          normalizedSource: trimmed,
          resolveInDart: true,
          directErrorCode: parsedOpfs.errorCode,
          directErrorMessage: parsedOpfs.errorMessage,
        );
      }
      return NormalizedAudioSource(
        normalizedSource: parsedOpfs.canonicalPath!,
        resolveInDart: false,
      );
    }
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: false,
    );
  }

  if (scheme == 'opfs') {
    if (!isWeb) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorUnsupported,
        directErrorMessage:
            'URI scheme "opfs://" ("$rawUri") is only supported on Web.',
      );
    }
    final parsedOpfs = parseOpfsPathStrict(trimmed);
    if (parsedOpfs.hasError) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: parsedOpfs.errorCode,
        directErrorMessage: parsedOpfs.errorMessage,
        strippedOpfsPrefix: true,
      );
    }
    return NormalizedAudioSource(
      normalizedSource: parsedOpfs.canonicalPath!,
      resolveInDart: false,
      strippedOpfsPrefix: true,
    );
  }

  if (scheme == 'icy') {
    return NormalizedAudioSource(
      normalizedSource: 'http://${trimmed.substring(6)}',
      resolveInDart: false,
    );
  }

  if (scheme == 'http' || scheme == 'https' || scheme == 'custom') {
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: false,
    );
  }

  if (scheme == 'blob') {
    if (isWeb) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: false,
      );
    }
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
      directErrorCode: MapResult.errorUnsupported,
      directErrorMessage:
          'URI "$rawUri" uses the browser "blob:" scheme, which is only '
          'supported on Flutter Web.',
    );
  }

  if (scheme == 'data') {
    final normalizedData = trimmed.startsWith('data://')
        ? 'data:${trimmed.substring('data://'.length)}'
        : trimmed;
    final commaIdx = normalizedData.indexOf(',');
    if (commaIdx < 'data:'.length) {
      return NormalizedAudioSource(
        normalizedSource: normalizedData,
        resolveInDart: true,
        directErrorCode: MapResult.errorInvalidArgs,
        directErrorMessage:
            'Malformed data URI "$rawUri": missing "," payload separator.',
      );
    }
    return NormalizedAudioSource(
      normalizedSource: normalizedData,
      resolveInDart: false,
    );
  }

  if (scheme == 'file') {
    if (isWeb) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorUnsupported,
        directErrorMessage:
            'Local filesystem "file://" URIs ("$rawUri") are not supported '
            'on Web browsers. Use a relative/absolute OPFS path, HTTP(S), '
            '"asset://", "data:", "blob:", or AudioSource(Uint8List).',
      );
    }
    try {
      final path = resolveFileUriToPath(trimmed, isWindows: isWindows);
      return NormalizedAudioSource(
        normalizedSource: path,
        resolveInDart: false,
      );
    } on UnsupportedError catch (e) {
      MapLogger.warn(
        'Unsupported file:// URI authority for "$rawUri": '
        '${e.message ?? e}',
      );
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorUnsupported,
        directErrorMessage: e.message ?? e.toString(),
      );
    } on Object catch (e) {
      MapLogger.warn('Malformed file:// URI "$rawUri": $e');
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorInvalidArgs,
        directErrorMessage: 'Invalid file URI "$rawUri": ${e.toString()}',
      );
    }
  }

  if (scheme == 'package') {
    final pkgRel = extractRelativeAssetKey(trimmed);
    final slashIdx = pkgRel.indexOf('/');
    if (slashIdx <= 0 || slashIdx + 1 >= pkgRel.length) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorInvalidArgs,
        directErrorMessage: 'Invalid package URI "$rawUri". Expected format '
            '"package:<package_name>/<asset_path>".',
      );
    }
    return _normalizeAssetKey(
      'packages/$pkgRel',
      isWeb: isWeb,
      webBaseUri: webBaseUri,
    );
  }

  if (scheme == 'asset') {
    final assetKey = extractRelativeAssetKey(trimmed);
    if (assetKey.isEmpty) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorInvalidArgs,
        directErrorMessage:
            'Empty asset key in "$rawUri". Expected "asset://assets/..." or '
            '"asset://packages/...".',
      );
    }
    return _normalizeAssetKey(
      assetKey,
      isWeb: isWeb,
      webBaseUri: webBaseUri,
    );
  }

  if (scheme == 'content' || scheme == 'android.resource') {
    if (!isWeb && isAndroid) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
      );
    }
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
      directErrorCode: MapResult.errorUnsupported,
      directErrorMessage:
          'URI scheme "$scheme://" ("$rawUri") is only supported on Android.',
    );
  }

  if (scheme == 'ws' || scheme == 'wss') {
    final parsed = Uri.tryParse(trimmed);
    if (parsed == null || parsed.host.isEmpty) {
      return NormalizedAudioSource(
        normalizedSource: trimmed,
        resolveInDart: true,
        directErrorCode: MapResult.errorInvalidArgs,
        directErrorMessage:
            'Invalid WebSocket URI "$rawUri": expected "$scheme://host[:port]/path".',
      );
    }
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
    );
  }

  if (_unsupportedNetworkSchemes.contains(scheme)) {
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
      directErrorCode: MapResult.errorUnsupported,
      directErrorMessage:
          'Protocol "$scheme://" is not supported directly by miniaudio_player. '
          'Download the file locally or serve it over HTTP(S) / CustomByteProvider.',
    );
  }

  if (_unsupportedStreamingSchemes.contains(scheme)) {
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
      directErrorCode: MapResult.errorUnsupported,
      directErrorMessage:
          'Real-time streaming protocol "$scheme://" is not supported directly. '
          'Proxy it as HTTP/HLS or stream decoded audio via CustomByteProvider.',
    );
  }

  if (_unsupportedAppleMediaSchemes.contains(scheme)) {
    return NormalizedAudioSource(
      normalizedSource: trimmed,
      resolveInDart: true,
      directErrorCode: MapResult.errorUnsupported,
      directErrorMessage:
          'Apple media library URI "$scheme://" cannot be opened directly '
          'without first exporting its playable URL or bytes in Swift/Objective-C.',
    );
  }

  MapLogger.verbose(
      'Rejected unsupported URI scheme "$scheme://" in "$rawUri".');
  return NormalizedAudioSource(
    normalizedSource: trimmed,
    resolveInDart: true,
    directErrorCode: MapResult.errorUnsupported,
    directErrorMessage:
        'Unsupported audio source URI scheme "$scheme://" in "$rawUri".',
  );
}

/// Normalizes a Flutter [assetKey] into either a Web HTTP asset URL (when
/// [isWeb] is `true`, optionally relative to [webBaseUri]) or a canonical
/// deferred `asset://` key on native targets.
NormalizedAudioSource _normalizeAssetKey(
  String assetKey, {
  required bool isWeb,
  Uri? webBaseUri,
}) {
  if (isWeb) {
    // Both `flutter run` (WebAssetServer) and `flutter build web` (profile/release)
    // serve assets at Flutter's double-encoded URL, whereas WebAssetServer rejects
    // HTTP HEAD probes with 404. Resolving directly avoids false 404 console errors
    // and streams progressively via Rust HTTP GET without buffering the full asset.
    final url = buildFlutterWebAssetUrl(
      assetKey,
      doubleEncode: true,
      baseUri: webBaseUri,
    );
    return NormalizedAudioSource(
      normalizedSource: url,
      resolveInDart: false,
    );
  }

  return NormalizedAudioSource(
    normalizedSource: 'asset://$assetKey',
    resolveInDart: true,
  );
}
