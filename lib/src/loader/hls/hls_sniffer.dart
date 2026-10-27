import 'dart:typed_data';

import '../../platform/http_helper.dart';

/// Sniffer utility for identifying HTTP Live Streaming (HLS / M3U8) playlists
/// purely via in-band magic bytes and out-of-band MIME types, without relying
/// on file extensions or URL paths.
class HlsSniffer {
  const HlsSniffer._();

  /// Standard and common MIME types associated with HLS playlists.
  static const Set<String> hlsMimeTypes = {
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/x-mpegurl',
    'audio/mpegurl',
    'application/mpegurl',
  };

  /// UTF-8 Byte Order Mark (BOM): 0xEF, 0xBB, 0xBF.
  static const List<int> utf8Bom = [0xEF, 0xBB, 0xBF];

  /// Sniffs whether the given byte payload starts with the mandatory HLS
  /// magic tag `#EXTM3U` (RFC 8216 Section 4.1), accounting for optional
  /// gzip compression, UTF-8 BOM, leading whitespace, and newlines.
  static bool isHlsBytes(List<int> bytes) {
    if (bytes.length < 2) return false;

    // Check if compressed with gzip (0x1F 0x8B)
    if (bytes[0] == 0x1F && bytes[1] == 0x8B) {
      final uncompressed = decompressIfGzip(
        bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      );
      if (identical(uncompressed, bytes)) return false;
      return isHlsBytes(uncompressed);
    }

    if (bytes.length < 7) return false;
    int offset = 0;

    // 1. Skip UTF-8 BOM if present
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      offset = 3;
    }

    // 2. Skip leading whitespace, empty lines, or carriage returns
    while (offset < bytes.length &&
        (bytes[offset] == 0x20 ||
            bytes[offset] == 0x09 ||
            bytes[offset] == 0x0A ||
            bytes[offset] == 0x0D)) {
      offset++;
    }

    if (offset + 7 > bytes.length) return false;

    // 3. Verify exact ASCII '#EXTM3U'
    return bytes[offset] == 0x23 && // '#'
        bytes[offset + 1] == 0x45 && // 'E'
        bytes[offset + 2] == 0x58 && // 'X'
        bytes[offset + 3] == 0x54 && // 'T'
        bytes[offset + 4] == 0x4D && // 'M'
        bytes[offset + 5] == 0x33 && // '3'
        bytes[offset + 6] == 0x55; // 'U'
  }

  /// Sniffs whether the provided [mime] string matches any known HLS playlist MIME type.
  static bool isHlsMime(String? mime) {
    if (mime == null || mime.isEmpty) return false;
    final clean = mime.split(';').first.trim().toLowerCase();
    return hlsMimeTypes.contains(clean);
  }

  /// Heuristic helper to check if a URI or URL path ends with or contains `.m3u8` or `.m3u`.
  /// Note: This is an optional heuristic hint; primary detection is always via [isHlsBytes] and [isHlsMime].
  static bool isHlsUrl(Uri uri) {
    final path = uri.path.toLowerCase();
    return path.endsWith('.m3u8') ||
        path.endsWith('.m3u') ||
        path.contains('.m3u8?') ||
        path.contains('.m3u?');
  }

  /// Evaluates whether the resource is an HLS playlist by inspecting both
  /// available magic bytes and optional MIME type.
  static bool isHls(List<int> bytes, {String? mime}) {
    return isHlsMime(mime) || isHlsBytes(bytes);
  }
}
