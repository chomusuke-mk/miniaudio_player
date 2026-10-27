import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../../api/player_exception.dart';
import '../../platform/http_helper.dart';
import '../audio_byte_provider.dart';
import 'hls_playlist_parser.dart';
import 'hls_segment_demuxer.dart';

/// An [AudioByteProvider] that seamlessly fetches, parses, demuxes, and streams
/// HTTP Live Streaming (HLS / M3U8) audio playlists (both continuous Live streams
/// and VOD tracks) without creating temporary disk files.
class HlsByteProvider extends AudioByteProvider {
  final Uri _uri;
  final Map<String, String>? headers;
  final void Function(Uint8List metaBytes)? onMetadataBytes;
  final String? initialManifest;
  final int maxRetries;

  bool _isClosed = false;
  bool _isLive = true;
  Uri? _activeMediaPlaylistUri;
  int _lastSequenceNumber = -1;

  void Function()? _activeHttpRequestAbort;
  Completer<void>? _resumeCompleter;
  bool _isPaused = false;
  int _streamGeneration = 0;

  HlsByteProvider(
    Uri uri, {
    this.headers,
    this.onMetadataBytes,
    this.initialManifest,
    bool isLiveHint = false,
    this.maxRetries = 5,
  })  : _uri = uri,
        _isLive = isLiveHint;

  @override
  String get sourceId => _uri.toString();

  @override
  Uri? get uri => _uri;

  @override
  bool get isLiveStream => _isLive;

  @override
  bool get isNetwork =>
      _uri.scheme.toLowerCase() == 'http' ||
      _uri.scheme.toLowerCase() == 'https';

  @override
  Future<AudioByteStreamResponse> open({int offset = 0, int? length}) async {
    _streamGeneration++;
    final int gen = _streamGeneration;
    _isClosed = false;
    _isPaused = false;
    _resumeCompleter = null;

    // 1. Fetch initial playlist manifest
    String manifestText;
    Uri playlistUri = _uri;

    if (initialManifest != null && initialManifest!.isNotEmpty) {
      manifestText = initialManifest!;
    } else {
      manifestText = await _fetchString(playlistUri, gen);
    }

    if (_isClosed || gen != _streamGeneration) {
      throw const MiniaudioPlayerException(
        'HLS open superseded',
        errorCode: MapResult.errorGeneric,
      );
    }

    // 2. Parse playlist (Master Multivariant vs Media)
    var playlist = HlsPlaylistParser.parse(manifestText, playlistUri);
    if (playlist.isMaster) {
      final bestVariantUri = playlist.selectBestVariantUri();
      if (bestVariantUri == null) {
        throw const MiniaudioPlayerException(
          'Master HLS playlist contains no playable audio variants',
          errorCode: MapResult.errorDecodeFailed,
        );
      }
      playlistUri = bestVariantUri;
      manifestText = await _fetchString(playlistUri, gen);
      playlist = HlsPlaylistParser.parse(manifestText, playlistUri);
    }

    _activeMediaPlaylistUri = playlistUri;
    _isLive = playlist.isLive;

    if (playlist.segments.isEmpty && !_isLive) {
      throw const MiniaudioPlayerException(
        'HLS playlist contains zero media segments',
        errorCode: MapResult.errorDecodeFailed,
      );
    }

    // 3. Create stream controller with reactive backpressure support
    final controller = StreamController<Uint8List>();
    controller.onPause = () {
      _isPaused = true;
      if (_resumeCompleter == null || _resumeCompleter!.isCompleted) {
        _resumeCompleter = Completer<void>();
      }
    };
    controller.onResume = () {
      _isPaused = false;
      final rc = _resumeCompleter;
      if (rc != null && !rc.isCompleted) {
        rc.complete();
      }
    };

    // 4. Start background streaming worker
    _startStreamingPipeline(controller, playlist, gen);

    return AudioByteStreamResponse(
      stream: controller.stream,
      totalBytes: _isLive ? -1 : 0,
      isSeekable: !_isLive,
      isLive: _isLive,
      contentType: 'audio/aac',
    );
  }

  void _startStreamingPipeline(
    StreamController<Uint8List> controller,
    HlsPlaylist initialPlaylist,
    int gen,
  ) async {
    final segmentQueue = <HlsMediaSegment>[];

    // Determine initial segment start:
    // For live streams, start near the live edge (last 3 segments) to guarantee
    // minimal latency and robust jitter protection.
    if (initialPlaylist.isLive) {
      final segs = initialPlaylist.segments;
      final startIndex = max(0, segs.length - 3);
      for (int i = startIndex; i < segs.length; i++) {
        segmentQueue.add(segs[i]);
      }
    } else {
      segmentQueue.addAll(initialPlaylist.segments);
    }

    double targetDuration = initialPlaylist.targetDuration;
    int consecutiveEmptyRefreshes = 0;

    try {
      while (!_isClosed && gen == _streamGeneration && !controller.isClosed) {
        // Handle backpressure suspension
        if (_isPaused) {
          final rc = _resumeCompleter;
          if (rc != null && !rc.isCompleted) {
            await rc.future;
          }
          if (_isClosed || gen != _streamGeneration) break;
        }

        // Process queued segments
        if (segmentQueue.isNotEmpty) {
          consecutiveEmptyRefreshes = 0;
          final segment = segmentQueue.removeAt(0);
          _lastSequenceNumber = segment.sequenceNumber;

          // Dispatch title if present in #EXTINF
          if (segment.title != null && segment.title!.isNotEmpty) {
            _dispatchTitleMetadata(segment.title!);
          }

          Uint8List? rawBytes;
          try {
            rawBytes = await _fetchBytes(segment.uri, gen);
          } catch (e) {
            // Segment fetch failed: on live streams, continue with next segment
            if (_isLive) {
              continue;
            }
            rethrow;
          }

          if (rawBytes.isNotEmpty) {
            // Demux and strip container headers (ID3, TS, etc.)
            final demuxed = HlsSegmentDemuxer.demuxSegment(rawBytes);

            if (demuxed.title != null && demuxed.title!.isNotEmpty) {
              _dispatchTitleMetadata(demuxed.title!);
            }

            if (demuxed.audioBytes.isNotEmpty) {
              controller.add(demuxed.audioBytes);
            }
          }
          continue;
        }

        // Queue is empty:
        if (!_isLive) {
          // VOD: all segments delivered cleanly
          break;
        }

        // Live: poll playlist for newly appended segments
        final pollIntervalMs = max(500, (targetDuration * 500).toInt());
        await Future<void>.delayed(Duration(milliseconds: pollIntervalMs));
        if (_isClosed || gen != _streamGeneration) break;

        final playlistUri = _activeMediaPlaylistUri ?? _uri;
        String updatedText;
        try {
          updatedText = await _fetchString(playlistUri, gen);
        } catch (_) {
          consecutiveEmptyRefreshes++;
          if (consecutiveEmptyRefreshes > 10) {
            throw const MiniaudioPlayerException(
              'HLS playlist refresh timed out after repeated failures',
              errorCode: MapResult.errorGeneric,
            );
          }
          continue;
        }

        final updatedPlaylist =
            HlsPlaylistParser.parse(updatedText, playlistUri);
        targetDuration = updatedPlaylist.targetDuration;

        // Discover newly appended segments
        for (final seg in updatedPlaylist.segments) {
          if (seg.sequenceNumber > _lastSequenceNumber &&
              !segmentQueue.any((s) => s.sequenceNumber == seg.sequenceNumber)) {
            segmentQueue.add(seg);
          }
        }

        if (segmentQueue.isEmpty) {
          consecutiveEmptyRefreshes++;
          if (!updatedPlaylist.isLive) {
            // Stream transitioned from live to finished
            break;
          }
        }
      }
    } catch (e) {
      if (!_isClosed && gen == _streamGeneration && !controller.isClosed) {
        controller.addError(e);
      }
    } finally {
      if (!controller.isClosed) {
        await controller.close();
      }
    }
  }

  void _dispatchTitleMetadata(String title) {
    if (onMetadataBytes != null) {
      // Synthesize an ICY stream title byte frame: StreamTitle='<title>';
      final frameText = "StreamTitle='$title';";
      final frameUnits = utf8.encode(frameText);
      final padLen = (16 - (frameUnits.length % 16)) % 16;
      final totalLen = frameUnits.length + padLen;
      final outBytes = Uint8List(1 + totalLen);
      outBytes[0] = (totalLen ~/ 16);
      outBytes.setRange(1, 1 + frameUnits.length, frameUnits);
      onMetadataBytes!(outBytes);
    }
  }

  Future<String> _fetchString(Uri targetUri, int gen) async {
    final bytes = await _fetchBytes(targetUri, gen);
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<Uint8List> _fetchBytes(Uri targetUri, int gen) async {
    int retries = 0;
    while (!_isClosed && gen == _streamGeneration) {
      RawHttpResponse res;
      try {
        res = await sendHttpGetRequest(
          targetUri,
          headers: headers ?? const {},
        );
      } catch (e) {
        retries++;
        if (retries >= maxRetries) {
          throw MiniaudioPlayerException(
            'Failed to fetch HLS resource $targetUri: $e',
            errorCode: MapResult.errorFileNotFound,
          );
        }
        await Future<void>.delayed(Duration(milliseconds: 200 * (1 << retries)));
        continue;
      }

      if (_isClosed || gen != _streamGeneration) {
        res.abort();
        throw const MiniaudioPlayerException(
          'HLS request superseded',
          errorCode: MapResult.errorGeneric,
        );
      }

      _activeHttpRequestAbort = res.abort;
      final statusCode = res.statusCode;

      if ((statusCode == 429 ||
              statusCode == 502 ||
              statusCode == 503 ||
              statusCode == 504) &&
          retries < maxRetries) {
        retries++;
        res.abort();
        await Future<void>.delayed(Duration(milliseconds: 300 * (1 << retries)));
        continue;
      }

      if (statusCode >= 400) {
        res.abort();
        throw MiniaudioPlayerException(
          'HTTP $statusCode (${res.reasonPhrase}) while fetching HLS segment $targetUri',
          errorCode: statusCode == 404
              ? MapResult.errorFileNotFound
              : (statusCode == 403 ? MapResult.errorAccessDenied : MapResult.errorGeneric),
        );
      }

      final builder = BytesBuilder(copy: false);
      final completer = Completer<Uint8List>();

      res.stream.listen(
        builder.add,
        onError: completer.completeError,
        onDone: () => completer.complete(builder.takeBytes()),
        cancelOnError: true,
      );

      final rawBytes = await completer.future;
      return decompressIfGzip(rawBytes);
    }

    throw const MiniaudioPlayerException(
      'HLS request cancelled',
      errorCode: MapResult.errorGeneric,
    );
  }

  @override
  Future<void> abortActiveStream() async {
    _streamGeneration++;
    _activeHttpRequestAbort?.call();
    _activeHttpRequestAbort = null;
    final rc = _resumeCompleter;
    if (rc != null && !rc.isCompleted) {
      rc.complete();
    }
  }

  @override
  Future<void> close() async {
    _isClosed = true;
    await abortActiveStream();
  }
}
