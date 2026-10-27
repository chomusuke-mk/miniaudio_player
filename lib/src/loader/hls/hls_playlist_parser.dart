import 'dart:typed_data';

/// Represents encryption key metadata defined by an `#EXT-X-KEY` tag.
class HlsKey {
  /// Encryption method, typically `'AES-128'`.
  final String method;

  /// Absolute URI pointing to the encryption key.
  final Uri uri;

  /// Initialization Vector (IV) if specified, or null (defaults to sequence number).
  final Uint8List? iv;

  const HlsKey({
    required this.method,
    required this.uri,
    this.iv,
  });
}

/// Represents an audio or media segment in an HLS media playlist.
class HlsMediaSegment {
  /// Fully resolved URI for downloading the segment.
  final Uri uri;

  /// Duration of the segment in seconds (from `#EXTINF`).
  final double duration;

  /// Title or track label embedded in `#EXTINF`, if any.
  final String? title;

  /// Continuous sequence number of this segment.
  final int sequenceNumber;

  /// Wall-clock date/time from `#EXT-X-PROGRAM-DATE-TIME`, if present.
  final DateTime? programDateTime;

  /// Encryption key definition for this segment, if encrypted.
  final HlsKey? key;

  /// True if an `#EXT-X-DISCONTINUITY` tag preceded this segment.
  final bool isDiscontinuity;

  const HlsMediaSegment({
    required this.uri,
    required this.duration,
    this.title,
    required this.sequenceNumber,
    this.programDateTime,
    this.key,
    this.isDiscontinuity = false,
  });
}

/// Represents a stream variant in an HLS master multivariant playlist.
class HlsVariantStream {
  /// Fully resolved URI pointing to the variant's media playlist.
  final Uri uri;

  /// Peak or average bandwidth in bits per second, if specified.
  final int? bandwidth;

  /// Codec descriptor string (e.g. `'mp4a.40.2'`), if specified.
  final String? codecs;

  /// Audio group identifier linking to an `#EXT-X-MEDIA:TYPE=AUDIO` track.
  final String? audioGroupId;

  const HlsVariantStream({
    required this.uri,
    this.bandwidth,
    this.codecs,
    this.audioGroupId,
  });
}

/// Parsed representation of an HLS playlist (Master Multivariant or Media).
class HlsPlaylist {
  /// Base URI from which this playlist was retrieved.
  final Uri baseUri;

  /// True if this is a Master playlist containing `#EXT-X-STREAM-INF` variants.
  final bool isMaster;

  /// True if this is a continuous Live stream (no `#EXT-X-ENDLIST` tag).
  final bool isLive;

  /// Target duration per segment in seconds (`#EXT-X-TARGETDURATION`).
  final double targetDuration;

  /// Initial media sequence number (`#EXT-X-MEDIA-SEQUENCE`).
  final int mediaSequence;

  /// Variants if this is a master playlist.
  final List<HlsVariantStream> variants;

  /// Segments if this is a media playlist.
  final List<HlsMediaSegment> segments;

  const HlsPlaylist({
    required this.baseUri,
    required this.isMaster,
    required this.isLive,
    this.targetDuration = 5.0,
    this.mediaSequence = 0,
    this.variants = const [],
    this.segments = const [],
  });

  /// Selects the best variant media playlist URI from this master playlist.
  /// Prefers audio-specific codecs and highest bandwidth, falling back to the first variant.
  Uri? selectBestVariantUri() {
    if (!isMaster || variants.isEmpty) return null;
    HlsVariantStream best = variants.first;
    for (final v in variants) {
      if ((v.bandwidth ?? 0) > (best.bandwidth ?? 0)) {
        best = v;
      }
    }
    return best.uri;
  }
}

/// Parser for RFC 8216 HLS playlists.
class HlsPlaylistParser {
  const HlsPlaylistParser._();

  /// Parses the raw text [content] of an HLS playlist resolved against [baseUri].
  static HlsPlaylist parse(String content, Uri baseUri) {
    final lines = content.split(RegExp(r'\r?\n'));
    bool isMaster = false;
    bool hasEndList = false;
    double targetDuration = 5.0;
    int mediaSequence = 0;

    final variants = <HlsVariantStream>[];
    final segments = <HlsMediaSegment>[];

    // Parser state
    int? currentBandwidth;
    String? currentCodecs;
    String? currentAudioGroupId;

    double? nextSegmentDuration;
    String? nextSegmentTitle;
    DateTime? nextProgramDateTime;
    HlsKey? currentKey;
    bool nextIsDiscontinuity = false;

    int segmentIndex = 0;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#')) {
        if (line.startsWith('#EXT-X-STREAM-INF:')) {
          isMaster = true;
          final params = line.substring('#EXT-X-STREAM-INF:'.length);
          currentBandwidth = _parseAttributeInt(params, 'BANDWIDTH');
          currentCodecs = _parseAttributeString(params, 'CODECS');
          currentAudioGroupId = _parseAttributeString(params, 'AUDIO');
        } else if (line.startsWith('#EXT-X-TARGETDURATION:')) {
          final val = line.substring('#EXT-X-TARGETDURATION:'.length).trim();
          targetDuration = double.tryParse(val) ?? 5.0;
        } else if (line.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
          final val = line.substring('#EXT-X-MEDIA-SEQUENCE:'.length).trim();
          mediaSequence = int.tryParse(val) ?? 0;
        } else if (line.startsWith('#EXT-X-ENDLIST')) {
          hasEndList = true;
        } else if (line.startsWith('#EXT-X-DISCONTINUITY')) {
          nextIsDiscontinuity = true;
        } else if (line.startsWith('#EXT-X-PROGRAM-DATE-TIME:')) {
          final val = line.substring('#EXT-X-PROGRAM-DATE-TIME:'.length).trim();
          nextProgramDateTime = DateTime.tryParse(val);
        } else if (line.startsWith('#EXTINF:')) {
          final raw = line.substring('#EXTINF:'.length).trim();
          final commaIdx = raw.indexOf(',');
          if (commaIdx != -1) {
            final durStr = raw.substring(0, commaIdx).trim();
            nextSegmentDuration = double.tryParse(durStr) ?? 5.0;
            var title = raw.substring(commaIdx + 1).trim();
            if (title.startsWith('title="') && title.endsWith('"')) {
              title = title.substring(7, title.length - 1);
            }
            nextSegmentTitle = title.isNotEmpty ? title : null;
          } else {
            nextSegmentDuration = double.tryParse(raw) ?? 5.0;
            nextSegmentTitle = null;
          }
        } else if (line.startsWith('#EXT-X-KEY:')) {
          final params = line.substring('#EXT-X-KEY:'.length);
          final method = _parseAttributeString(params, 'METHOD') ?? 'NONE';
          if (method.toUpperCase() == 'NONE') {
            currentKey = null;
          } else {
            final uriStr = _parseAttributeString(params, 'URI');
            if (uriStr != null) {
              final keyUri = baseUri.resolve(uriStr);
              final ivHex = _parseAttributeString(params, 'IV');
              Uint8List? ivBytes;
              if (ivHex != null && ivHex.startsWith('0x')) {
                ivBytes = _parseHexBytes(ivHex.substring(2));
              }
              currentKey = HlsKey(method: method, uri: keyUri, iv: ivBytes);
            }
          }
        }
      } else {
        // Non-comment line: URI for variant or media segment
        final resolvedUri = baseUri.resolve(line);

        if (isMaster) {
          variants.add(
            HlsVariantStream(
              uri: resolvedUri,
              bandwidth: currentBandwidth,
              codecs: currentCodecs,
              audioGroupId: currentAudioGroupId,
            ),
          );
          currentBandwidth = null;
          currentCodecs = null;
          currentAudioGroupId = null;
        } else {
          final segDuration = nextSegmentDuration ?? targetDuration;
          final segSeq = mediaSequence + segmentIndex;
          segments.add(
            HlsMediaSegment(
              uri: resolvedUri,
              duration: segDuration,
              title: nextSegmentTitle,
              sequenceNumber: segSeq,
              programDateTime: nextProgramDateTime,
              key: currentKey,
              isDiscontinuity: nextIsDiscontinuity,
            ),
          );
          segmentIndex++;
          nextSegmentDuration = null;
          nextSegmentTitle = null;
          nextProgramDateTime = null;
          nextIsDiscontinuity = false;
        }
      }
    }

    return HlsPlaylist(
      baseUri: baseUri,
      isMaster: isMaster,
      isLive: !hasEndList,
      targetDuration: targetDuration,
      mediaSequence: mediaSequence,
      variants: variants,
      segments: segments,
    );
  }

  static String? _parseAttributeString(String params, String key) {
    final pattern = RegExp('$key=(?:"([^"]*)"|([^,]+))', caseSensitive: false);
    final match = pattern.firstMatch(params);
    if (match != null) {
      return match.group(1) ?? match.group(2);
    }
    return null;
  }

  static int? _parseAttributeInt(String params, String key) {
    final str = _parseAttributeString(params, key);
    return str != null ? int.tryParse(str) : null;
  }

  static Uint8List _parseHexBytes(String hex) {
    final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    final bytes = Uint8List(clean.length ~/ 2);
    for (int i = 0; i < bytes.length; i++) {
      bytes[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return bytes;
  }
}
