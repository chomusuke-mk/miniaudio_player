import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../api/track_metadata.dart';

/// Demuxed and normalized result from an HLS media segment.
class HlsDemuxResult {
  /// Clean, unbroken audio elementary stream frames (e.g. ADTS AAC or MP3),
  /// with any container headers (ID3v2 tags, MPEG-2 TS framing) cleanly stripped.
  final Uint8List audioBytes;

  /// Detected audio codec for this segment.
  final AudioCodec codec;

  /// Optional track title extracted from ID3v2 TIT2 frame or segment metadata.
  final String? title;

  /// Optional artist name extracted from ID3v2 TPE1 frame.
  final String? artist;

  const HlsDemuxResult({
    required this.audioBytes,
    required this.codec,
    this.title,
    this.artist,
  });
}

/// Lightweight, high-speed demuxer for HLS audio segments.
/// Handles raw ADTS AAC (.aac), MPEG audio (.mp3), and MPEG-2 Transport Stream (.ts).
class HlsSegmentDemuxer {
  const HlsSegmentDemuxer._();

  /// Demuxes and normalizes [rawBytes] into clean audio elementary frames.
  static HlsDemuxResult demuxSegment(Uint8List rawBytes) {
    if (rawBytes.isEmpty) {
      return HlsDemuxResult(
        audioBytes: Uint8List(0),
        codec: AudioCodec.unknown,
      );
    }

    // 1. Check if the segment is an MPEG-2 Transport Stream (.ts)
    if (_isMpegTs(rawBytes)) {
      return _demuxMpegTs(rawBytes);
    }

    // 2. Strip leading ID3v2 tag if present (common in .aac and .mp3 HLS segments)
    int audioStart = 0;
    String? id3Title;
    String? id3Artist;

    if (_hasId3v2(rawBytes)) {
      final id3Info = _parseAndSkipId3v2(rawBytes);
      audioStart = id3Info.audioOffset;
      id3Title = id3Info.title;
      id3Artist = id3Info.artist;
    }

    final audioBytes = (audioStart > 0 && audioStart < rawBytes.length)
        ? Uint8List.sublistView(rawBytes, audioStart)
        : rawBytes;

    // 3. Sniff elementary audio format
    final codec = _detectElementaryCodec(audioBytes);

    return HlsDemuxResult(
      audioBytes: audioBytes,
      codec: codec,
      title: id3Title,
      artist: id3Artist,
    );
  }

  /// Checks if the buffer starts with the MPEG-2 TS sync byte (0x47) at 188-byte intervals.
  static bool _isMpegTs(Uint8List bytes) {
    if (bytes.length < 188) return false;
    if (bytes[0] != 0x47) return false;
    if (bytes.length >= 376 && bytes[188] != 0x47) return false;
    return true;
  }

  /// Demuxes audio elementary stream from MPEG-2 Transport Stream packets.
  static HlsDemuxResult _demuxMpegTs(Uint8List bytes) {
    const packetSize = 188;
    final packetCount = bytes.length ~/ packetSize;
    if (packetCount == 0) {
      return HlsDemuxResult(audioBytes: bytes, codec: AudioCodec.unknown);
    }

    int audioPid = -1;
    final pesBuilder = BytesBuilder(copy: false);

    // Pass 1: Find Audio PID by scanning PES audio stream ID (0xC0..0xDF)
    for (int i = 0; i < packetCount; i++) {
      final pOffset = i * packetSize;
      if (bytes[pOffset] != 0x47) continue;

      final pusi = (bytes[pOffset + 1] & 0x40) != 0;
      final pid = ((bytes[pOffset + 1] & 0x1F) << 8) | bytes[pOffset + 2];
      if (pid == 0 || pid == 0x1FFF) continue; // Skip PAT and null packets

      if (pusi) {
        int payloadOffset = pOffset + 4;
        final afc = (bytes[pOffset + 3] >> 4) & 0x03;
        if (afc == 2) continue; // Adaptation field only
        if (afc == 3) {
          final adaptLen = bytes[payloadOffset];
          payloadOffset += 1 + adaptLen;
        }

        if (payloadOffset + 3 < pOffset + packetSize) {
          // Check for PES prefix 0x000001
          if (bytes[payloadOffset] == 0x00 &&
              bytes[payloadOffset + 1] == 0x00 &&
              bytes[payloadOffset + 2] == 0x01) {
            final streamId = bytes[payloadOffset + 3];
            // 0xC0..0xDF is standard MPEG audio / AAC stream ID
            if (streamId >= 0xC0 && streamId <= 0xDF) {
              audioPid = pid;
              break;
            }
          }
        }
      }
    }

    if (audioPid == -1) {
      // Fallback: If not found, use first non-system PID
      for (int i = 0; i < packetCount; i++) {
        final pOffset = i * packetSize;
        final pid = ((bytes[pOffset + 1] & 0x1F) << 8) | bytes[pOffset + 2];
        if (pid > 0x10 && pid < 0x1FFF) {
          audioPid = pid;
          break;
        }
      }
    }

    // Pass 2: Extract audio PES payload
    for (int i = 0; i < packetCount; i++) {
      final pOffset = i * packetSize;
      if (bytes[pOffset] != 0x47) continue;

      final pusi = (bytes[pOffset + 1] & 0x40) != 0;
      final pid = ((bytes[pOffset + 1] & 0x1F) << 8) | bytes[pOffset + 2];
      if (pid != audioPid) continue;

      int payloadOffset = pOffset + 4;
      final afc = (bytes[pOffset + 3] >> 4) & 0x03;
      if (afc == 2) continue; // Adaptation field only
      if (afc == 3) {
        final adaptLen = bytes[payloadOffset];
        payloadOffset += 1 + adaptLen;
      }

      final payloadEnd = pOffset + packetSize;
      if (payloadOffset >= payloadEnd) continue;

      if (pusi) {
        // Strip PES packet header
        if (payloadOffset + 9 <= payloadEnd &&
            bytes[payloadOffset] == 0x00 &&
            bytes[payloadOffset + 1] == 0x00 &&
            bytes[payloadOffset + 2] == 0x01) {
          final pesHeaderDataLen = bytes[payloadOffset + 8];
          payloadOffset += 9 + pesHeaderDataLen;
        }
      }

      if (payloadOffset < payloadEnd) {
        pesBuilder.add(bytes.sublist(payloadOffset, payloadEnd));
      }
    }

    final rawElementary = pesBuilder.takeBytes();
    return demuxSegment(rawElementary);
  }

  /// Checks if [bytes] start with an ID3v2 tag.
  static bool _hasId3v2(Uint8List bytes) {
    return bytes.length >= 10 &&
        bytes[0] == 0x49 && // 'I'
        bytes[1] == 0x44 && // 'D'
        bytes[2] == 0x33 && // '3'
        bytes[3] < 0xFF && // Version < 255
        bytes[4] < 0xFF && // Revision < 255
        (bytes[6] & 0x80) == 0 && // Syncsafe validation
        (bytes[7] & 0x80) == 0 &&
        (bytes[8] & 0x80) == 0 &&
        (bytes[9] & 0x80) == 0;
  }

  /// Parses ID3v2 metadata frames and returns the byte offset where audio begins.
  static _Id3ParseResult _parseAndSkipId3v2(Uint8List bytes) {
    if (!_hasId3v2(bytes)) {
      return const _Id3ParseResult(audioOffset: 0);
    }

    final flags = bytes[5];
    final bool hasFooter = (flags & 0x10) != 0;

    // Syncsafe integer for size
    final int tagSize = ((bytes[6] & 0x7F) << 21) |
        ((bytes[7] & 0x7F) << 14) |
        ((bytes[8] & 0x7F) << 7) |
        (bytes[9] & 0x7F);

    int totalId3Size = 10 + tagSize;
    if (hasFooter) {
      totalId3Size += 10;
    }

    String? title;
    String? artist;

    // Parse frames inside ID3 tag
    try {
      int cursor = 10;
      final end = min(totalId3Size, bytes.length);
      while (cursor + 10 <= end) {
        // Frame ID (4 ASCII characters)
        final frameId = String.fromCharCodes(bytes.sublist(cursor, cursor + 4));
        if (frameId.codeUnits.any((c) => c < 32 || c > 126)) break;

        final frameSize = (bytes[cursor + 4] << 24) |
            (bytes[cursor + 5] << 16) |
            (bytes[cursor + 6] << 8) |
            bytes[cursor + 7];
        cursor += 10;

        if (frameSize <= 0 || cursor + frameSize > end) break;

        if (frameId == 'TIT2') {
          title = _decodeId3String(bytes.sublist(cursor, cursor + frameSize));
        } else if (frameId == 'TPE1') {
          artist = _decodeId3String(bytes.sublist(cursor, cursor + frameSize));
        }

        cursor += frameSize;
      }
    } catch (_) {
      // Ignore frame parsing errors, still safely return the audio offset
    }

    return _Id3ParseResult(
      audioOffset: min(totalId3Size, bytes.length),
      title: title,
      artist: artist,
    );
  }

  static String? _decodeId3String(Uint8List data) {
    if (data.isEmpty) return null;
    final encoding = data[0];
    final body = data.sublist(1);
    try {
      if (encoding == 0) {
        // ISO-8859-1
        return latin1.decode(body).trim();
      } else if (encoding == 1 || encoding == 2) {
        // UTF-16
        return utf8.decode(body, allowMalformed: true).trim();
      } else {
        // UTF-8
        return utf8.decode(body, allowMalformed: true).trim();
      }
    } catch (_) {
      return null;
    }
  }

  /// Detects the underlying elementary audio codec from raw audio bitstream frames.
  static AudioCodec _detectElementaryCodec(Uint8List bytes) {
    if (bytes.length >= 2) {
      // AAC ADTS syncword (0xFFF or 0xFF followed by 0xF0..0xF6)
      if (bytes[0] == 0xFF && (bytes[1] & 0xF6) == 0xF0) {
        return AudioCodec.aac;
      }
      // MP3 syncword (0xFF followed by 0xE0..0xFE)
      if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
        return AudioCodec.mp3;
      }
    }
    return AudioCodec.detect(bytes);
  }
}

class _Id3ParseResult {
  final int audioOffset;
  final String? title;
  final String? artist;

  const _Id3ParseResult({
    required this.audioOffset,
    this.title,
    this.artist,
  });
}
