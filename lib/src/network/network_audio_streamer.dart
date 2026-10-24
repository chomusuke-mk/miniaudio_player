import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/miniaudio_player.dart';
import '../api/player_exception.dart';
import '../api/track_metadata.dart';
import '../ffi/native_types.dart';

/// Manages asynchronous HTTP/HTTPS progressive and live streaming for [MiniaudioPlayer].
///
/// Features:
/// - Progressive downloading with HTTP Byte-Range requests for arbitrary seeking.
/// - Adaptive backpressure flow control (pausing network download when C buffer is full).
/// - Live stream support with circular jitter buffer and infinite lifespan.
/// - Resilient error handling (HTTP status codes, connection drops, network timeouts).
class NetworkAudioStreamer {
  static const String _defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 miniaudio_player/1.0';

  final MiniaudioPlayer _player;
  final Uri _uri;
  final Map<String, String>? _headers;
  final bool _isLive;
  final Duration _bufferAhead;
  final Duration _bufferBehind;

  HttpClient? _client;
  StreamSubscription<List<int>>? _responseSub;
  StreamIterator<List<int>>? _currentIterator;
  Timer? _backpressureTimer;
  Timer? _prefetchTimer;
  Completer<void>? _probeCompleter;

  bool _isDisposed = false;
  int _totalContentLength = -1;
  int _currentStreamOffset = 0;
  bool _isRangeSupported = false;
  int _seekGeneration = 0;
  bool _isPausedByBackpressure = false;
  bool _isStreamEnded = false;
  bool _hasPinnedHead = false;
  int _pinnedHeadSize = 256 * 1024;
  int _readCursorByte = 0;
  int _rangeStart = 0;
  int _rangeEnd = 0;
  int _aheadHeadroomBytes = 0;
  AudioCodec _detectedCodec = AudioCodec.unknown;
  Timer? _reconnectTimer;
  int _reconnectRetries = 0;
  static const int _maxReconnectRetries = 5;

  void _log(int level, String message) {
    if (MiniaudioPlayer.globalConfig.logLevel.value >= level) {
      final tag = level == MapLogLevel.error
          ? 'ERROR'
          : (level == MapLogLevel.warning ? 'WARN' : 'DEBUG');
      stderr.writeln('[miniaudio_player][$tag][network] $message');
    }
  }

  /// Current byte offset reached in the decoder read cursor.
  int get readCursorByte => _readCursorByte;

  /// Earliest continuous byte offset held in the native buffer.
  int get rangeStart => _rangeStart;

  /// Furthest continuous byte offset held in the native buffer.
  int get rangeEnd => _rangeEnd;

  /// Lookahead forward headroom in bytes ahead of the reading cursor.
  int get aheadHeadroomBytes => _aheadHeadroomBytes;

  /// Whether HTTP Range requests are supported by the server.
  bool get isRangeSupported => _isRangeSupported;

  /// Whether initial chunks/headers are retained in RAM for instant zero-cost replay.
  bool get hasPinnedHead => !_isDisposed && _hasPinnedHead;

  /// Current byte offset reached in the network stream.
  int get currentStreamOffset => _currentStreamOffset;

  /// Total content length in bytes if advertised by the server, or -1.
  int get totalContentLength => _totalContentLength;

  /// Configured ahead-buffer duration.
  Duration get bufferAhead => _bufferAhead;

  /// Configured behind-buffer duration retained in circular RAM cache.
  Duration get bufferBehind => _bufferBehind;

  /// Whether the network download stream has completed (reached EOF).
  bool get isStreamEnded => _isStreamEnded;

  bool _isStopped = false;

  /// Whether the streamer is currently stopped via stop().
  bool get isStopped => _isStopped;

  /// Whether the backpressure monitoring timer is currently active.
  bool get isBackpressureActive =>
      _backpressureTimer != null && _backpressureTimer!.isActive;

  NetworkAudioStreamer(
    this._player, {
    required Uri uri,
    Map<String, String>? headers,
    bool isLive = false,
    Duration bufferAhead = const Duration(seconds: 30),
    Duration bufferBehind = const Duration(seconds: 15),
  })  : _uri = uri,
        _headers = headers,
        _isLive = isLive,
        _bufferAhead = bufferAhead,
        _bufferBehind = bufferBehind;

  /// Starts connecting to the remote audio URI, buffers initial frames,
  /// and configures the native streaming decoder.
  Future<void> start() async {
    _player.ensureNotDisposed();
    _isStreamEnded = false;
    _isStopped = false;

    _client = HttpClient()
      ..userAgent = _defaultUserAgent
      ..autoUncompress = false;

    // 1. Send initial request (with retry for transient 429/503 rate limits)
    HttpClientResponse res;
    int openRetries = 0;
    while (true) {
      try {
        final req = await _client!.getUrl(_uri);
        _applyCommonHeaders(req);
        res = await req.close();
      } catch (e) {
        _disposeClient();
        throw MiniaudioPlayerException(
          'Failed to connect to $_uri: $e',
          errorCode: MapResult.errorFileNotFound,
        );
      }

      if ((res.statusCode == 429 || res.statusCode == 503) && openRetries < 3) {
        openRetries++;
        _log(MapLogLevel.warning, 'HTTP ${res.statusCode} (${res.reasonPhrase}) while opening $_uri (retry $openRetries/3)');
        try {
          await res.drain<void>();
        } catch (_) {}
        final retryAfter = int.tryParse(res.headers.value(HttpHeaders.retryAfterHeader) ?? '') ?? 1;
        await Future<void>.delayed(Duration(milliseconds: min(2000, max(500, retryAfter * 1000))));
        continue;
      }
      break;
    }

    if (res.statusCode >= 400) {
      _log(MapLogLevel.error, 'HTTP ${res.statusCode} (${res.reasonPhrase}) while opening $_uri');
      _disposeClient();
      throw MiniaudioPlayerException(
        'HTTP ${res.statusCode} (${res.reasonPhrase}) while opening $_uri',
        errorCode: res.statusCode == 404
            ? MapResult.errorFileNotFound
            : (res.statusCode == 403 ? MapResult.errorAccessDenied : res.statusCode),
      );
    }

    _totalContentLength = res.contentLength;
    final acceptRanges = res.headers.value(HttpHeaders.acceptRangesHeader);
    _isRangeSupported = acceptRanges == 'bytes';
    final contentType = res.headers.value(HttpHeaders.contentTypeHeader);
    final isLiveStream = _isLive ||
        _totalContentLength <= 0 ||
        res.headers.value(HttpHeaders.transferEncodingHeader) == 'chunked';

    // 2. Pre-buffer initial chunk for format probing in C using subscription
    var targetProbeSize = 65536;
    _probeCompleter = Completer<void>();
    final initialBuilder = BytesBuilder(copy: false);
    var streamDone = false;

    final icyMetaint = int.tryParse(res.headers.value('icy-metaint') ?? '') ?? 0;
    final Stream<List<int>> audioStream = icyMetaint > 0
        ? res.transform(_createIcyDemuxTransformer(icyMetaint))
        : res;

    _responseSub = audioStream.listen(
      (chunk) async {
        final pc = _probeCompleter;
        if (pc != null && !pc.isCompleted) {
          initialBuilder.add(chunk);
          if (initialBuilder.length >= targetProbeSize) {
            _responseSub?.pause();
            if (!pc.isCompleted) {
              pc.complete();
            }
          }
        } else {
          _responseSub?.pause();
          try {
            await _feedChunk(chunk, 0);
          } finally {
            if (!_isDisposed && _seekGeneration == 0 && _responseSub != null && !_isPausedByBackpressure) {
              _responseSub!.resume();
            }
          }
        }
      },
      onError: (err) {
        final pc = _probeCompleter;
        if (pc != null && !pc.isCompleted) {
          pc.completeError(err);
        } else if (_seekGeneration == 0) {
          _onStreamError(err);
        }
      },
      onDone: () {
        streamDone = true;
        final pc = _probeCompleter;
        if (pc != null && !pc.isCompleted) {
          pc.complete();
        } else if (_seekGeneration == 0) {
          _onStreamDone();
        }
      },
      cancelOnError: true,
    );

    try {
      await _probeCompleter!.future;
    } catch (e) {
      _disposeClient();
      throw MiniaudioPlayerException(
        'Connection interrupted while buffering stream from $_uri: $e',
        errorCode: MapResult.errorGeneric,
      );
    }

    if (initialBuilder.isEmpty) {
      _disposeClient();
      throw const MiniaudioPlayerException('Empty audio stream received');
    }

    // 3. Initialize native streaming engine with adaptive probing (sniffing format from probeBytes)
    int openRes = MapResult.errorGeneric;
    AudioCodec detectedCodec = AudioCodec.unknown;
    while (!_isDisposed) {
      final probeBytes = initialBuilder.toBytes();
      _currentStreamOffset = probeBytes.length;
      detectedCodec = AudioCodec.detect(probeBytes, mime: contentType);
      _detectedCodec = detectedCodec;
      final encodingFormat = _detectEncodingFormat(probeBytes, contentType);

      final totalDuration = _bufferAhead + _bufferBehind;
      final nominalBitrate = _player.state.audioBitrate > 0 ? _player.state.audioBitrate : 256000;
      final bytesPerSec = nominalBitrate ~/ 8;
      int calculatedCap = (totalDuration.inMilliseconds * bytesPerSec) ~/ 1000;

      if (isLiveStream && MiniaudioPlayer.globalConfig.bufferSizeLiveStreamMB != null) {
        calculatedCap = MiniaudioPlayer.globalConfig.bufferSizeLiveStreamMB! * 1024 * 1024;
      } else if (!isLiveStream && MiniaudioPlayer.globalConfig.bufferSizeNetworkMB != null) {
        calculatedCap = MiniaudioPlayer.globalConfig.bufferSizeNetworkMB! * 1024 * 1024;
      } else if (!isLiveStream) {
        calculatedCap = max(calculatedCap, 8 * 1024 * 1024);
      }

      if (_totalContentLength > 0 && calculatedCap > 0 && _totalContentLength <= calculatedCap) {
        calculatedCap = max(calculatedCap, _totalContentLength + 65536);
      }
      final bufferCap = max(max(256 * 1024, probeBytes.length * 2), calculatedCap);

      final isMp4 = probeBytes.length >= 8 &&
          probeBytes[4] == 0x66 &&
          probeBytes[5] == 0x74 &&
          probeBytes[6] == 0x79 &&
          probeBytes[7] == 0x70;

      final initPtr = malloc.allocate<Uint8>(probeBytes.length);
      initPtr.asTypedList(probeBytes.length).setAll(0, probeBytes);
      try {
        openRes = native.miniaudio_player_open_stream(
          _player.handle,
          initPtr.cast(),
          probeBytes.length,
          isLiveStream ? -1 : _totalContentLength,
          isLiveStream ? 1 : 0,
          bufferCap,
          encodingFormat,
        );
      } finally {
        malloc.free(initPtr);
      }

      // If MP4 container failed format probing (likely non-faststart with 'moov' atom at EOF):
      // Perform Tail Probing by fetching the last ~256 KB via HTTP Byte-Range request.
      if (openRes == MapResult.errorDecodeFailed && isMp4 && !isLiveStream && _totalContentLength > probeBytes.length) {
        final tailSize = min(256 * 1024, _totalContentLength - probeBytes.length);
        final tailStart = _totalContentLength - tailSize;
        try {
          final tailReq = await _client!.getUrl(_uri);
          _applyCommonHeaders(tailReq);
          tailReq.headers.set(HttpHeaders.rangeHeader, 'bytes=$tailStart-${_totalContentLength - 1}');
          final tailRes = await tailReq.close();
          if (tailRes.statusCode == 206) {
            final tailBytes = await tailRes
                .fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d))
                .then((b) => b.takeBytes());

            if (tailBytes.isNotEmpty) {
              final headPtr = malloc.allocate<Uint8>(probeBytes.length);
              final tailPtr = malloc.allocate<Uint8>(tailBytes.length);
              headPtr.asTypedList(probeBytes.length).setAll(0, probeBytes);
              tailPtr.asTypedList(tailBytes.length).setAll(0, tailBytes);
              try {
                openRes = native.miniaudio_player_open_stream_ex(
                  _player.handle,
                  headPtr.cast(),
                  probeBytes.length,
                  tailPtr.cast(),
                  tailBytes.length,
                  _totalContentLength,
                  0,
                  bufferCap,
                  encodingFormat,
                );
              } finally {
                malloc.free(headPtr);
                malloc.free(tailPtr);
              }
            }
          }
        } catch (_) {
          // Range request failed or interrupted; will fall back below
        }
      }

      if (openRes == MapResult.success) {
        // If container metadata extends beyond initial probe (e.g. giant FLAC PICTURE or ID3 art),
        // buffer up to audioDataOffset so the full Head metadata is retained in RAM.
        final detectedAudioOffset =
            native.miniaudio_player_get_audio_data_offset(_player.handle);
        if (detectedAudioOffset > probeBytes.length &&
            !isLiveStream &&
            !streamDone) {
          final maxProbe = (_totalContentLength > 0 &&
                  _totalContentLength <= bufferCap)
              ? _totalContentLength
              : min(bufferCap, 8 * 1024 * 1024);
          if (targetProbeSize < maxProbe &&
              probeBytes.length < detectedAudioOffset) {
            targetProbeSize = min(
                max(detectedAudioOffset, targetProbeSize + 1024 * 1024),
                maxProbe);
            _probeCompleter = Completer<void>();
            _responseSub?.resume();
            try {
              await _probeCompleter!.future;
            } catch (_) {
              break;
            }
            continue;
          }
        }

        _hasPinnedHead = true;
        _pinnedHeadSize = min(256 * 1024, probeBytes.length);
        if (_totalContentLength > 0 && _totalContentLength < _pinnedHeadSize) {
          _pinnedHeadSize = _totalContentLength;
        }
        if (streamDone || (_totalContentLength > 0 && probeBytes.length >= _totalContentLength)) {
          _isStreamEnded = true;
        }
        break;
      }

      // If decode failed and we can buffer more for format detection (e.g. large ID3/OpusTags cover art or non-range MP4)
      if (openRes == MapResult.errorDecodeFailed && !isLiveStream && !streamDone) {
        final maxProbe = (_totalContentLength > 0 && _totalContentLength <= bufferCap)
            ? _totalContentLength
            : min(bufferCap, 8 * 1024 * 1024);
        if (targetProbeSize < maxProbe) {
          targetProbeSize = min(targetProbeSize + 1024 * 1024, maxProbe);
          _probeCompleter = Completer<void>();
          _responseSub?.resume();
          try {
            await _probeCompleter!.future;
          } catch (_) {
            break;
          }
          continue;
        }
      }

      break;
    }

    if (openRes != MapResult.success) {
      _disposeClient();
      throw MiniaudioPlayerException(
        'Failed to initialize native streaming engine: ${MapResult.describe(openRes)}',
        errorCode: openRes,
      );
    }


    // 4. If Range requests are supported and container can have tail metadata (e.g. Ogg EOS page, ID3v1, APEv2),
    // probe the tail synchronously before unpausing stream to resolve exact duration and metadata.
    if (_isRangeSupported &&
        !isLiveStream &&
        _totalContentLength > 65536 &&
        _detectedCodec != AudioCodec.pcm &&
        _detectedCodec != AudioCodec.aac &&
        _detectedCodec != AudioCodec.alac) {
      await _probeTailAsync();
    }

    // 5. Set persistent track metadata for UI and seek inspection
    final audioDataOffset = native.miniaudio_player_get_audio_data_offset(_player.handle);
    final trackMeta = AudioTrackMetadata(
      codec: detectedCodec,
      format: AudioFormat.fromCodec(detectedCodec),
      formatName: detectedCodec.name,
      duration: _player.state.duration,
      totalBytes: _totalContentLength,
      bitrate: _player.state.audioBitrate,
      sampleRate: _player.sampleRate,
      channels: _player.channels,
      isNetwork: true,
      isLiveStream: isLiveStream,
      uri: _uri,
      audioDataOffset: audioDataOffset > 0 ? audioDataOffset : 0,
    );
    _player.setTrackMetadata(trackMeta);

    // 6. Start adaptive backpressure flow control and resume subscription if paused
    _startBackpressureMonitor();
    if (_responseSub != null && _responseSub!.isPaused && !_isPausedByBackpressure) {
      _responseSub!.resume();
    }
  }

  void _listenToResponse(HttpClientResponse res, int seekGen) {
    if (_isDisposed) return;
    _startBackpressureMonitor();
    final icyMetaint = int.tryParse(res.headers.value('icy-metaint') ?? '') ?? 0;
    final Stream<List<int>> audioStream = icyMetaint > 0
        ? res.transform(_createIcyDemuxTransformer(icyMetaint))
        : res;
    _responseSub = audioStream.listen(
      (chunk) async {
        _responseSub?.pause();
        try {
          await _feedChunk(chunk, seekGen);
        } finally {
          if (!_isDisposed && _seekGeneration == seekGen && _responseSub != null && !_isPausedByBackpressure) {
            _responseSub!.resume();
          }
        }
      },
      onError: (err) {
        if (_seekGeneration == seekGen) {
          _onStreamError(err);
        }
      },
      onDone: () {
        if (_seekGeneration == seekGen) {
          _onStreamDone();
        }
      },
      cancelOnError: true,
    );
  }

  Future<void> _feedChunk(List<int> chunk, int seekGen) async {
    if (_isDisposed || _seekGeneration != seekGen) return;

    const int sliceSize = 32768; // 32 KB slices
    int offset = 0;
    while (!_isDisposed && _seekGeneration == seekGen && offset < chunk.length) {
      final end = (offset + sliceSize < chunk.length) ? offset + sliceSize : chunk.length;
      final sliceLen = end - offset;

      final ptr = malloc.allocate<Uint8>(sliceLen);
      try {
        ptr.asTypedList(sliceLen).setRange(0, sliceLen, chunk, offset);
        var feedRes = native.miniaudio_player_stream_feed(
          _player.handle,
          ptr.cast(),
          sliceLen,
        );

        if (feedRes != MapResult.success) {
          _responseSub?.pause();
          _isPausedByBackpressure = true;
          while (!_isDisposed && _seekGeneration == seekGen) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            if (_isDisposed || _seekGeneration != seekGen) break;

            feedRes = native.miniaudio_player_stream_feed(
              _player.handle,
              ptr.cast(),
              sliceLen,
            );
            if (feedRes == MapResult.success) {
              break;
            }
          }
        }

        if (feedRes == MapResult.success) {
          _reconnectRetries = 0;
          _currentStreamOffset += sliceLen;
          if (seekGen == 0 && _pinnedHeadSize < 256 * 1024) {
            _pinnedHeadSize = min(256 * 1024, _currentStreamOffset);
            if (_totalContentLength > 0 && _totalContentLength < _pinnedHeadSize) {
              _pinnedHeadSize = _totalContentLength;
            }
          }
          offset += sliceLen;
        } else {
          break;
        }
      } finally {
        malloc.free(ptr);
      }
    }
  }

  void _onStreamError(Object error) {
    if (_isDisposed) return;
    _log(MapLogLevel.error, 'Stream error on $_uri: $error');
    _isStreamEnded = true;
    // Signal end or error to C stream
    native.miniaudio_player_stream_end(_player.handle);
  }

  void _onStreamDone() {
    if (_isDisposed) return;
    if (!_isLive && _totalContentLength > 0 && _currentStreamOffset < _totalContentLength) {
      if (_reconnectRetries < _maxReconnectRetries) {
        final retryDelayMs = (100 * (1 << _reconnectRetries)).clamp(100, 2000);
        _reconnectRetries++;
        final thisSeekGen = _seekGeneration;
        _reconnectTimer?.cancel();
        _reconnectTimer = Timer(Duration(milliseconds: retryDelayMs), () {
          if (_isDisposed || _seekGeneration != thisSeekGen) return;
          _reconnectStream(thisSeekGen);
        });
        return;
      }
      return;
    }
    if (_isLive) {
      return;
    }
    _isStreamEnded = true;
    native.miniaudio_player_stream_end(_player.handle);
  }

  Future<void> _reconnectStream(int seekGen) async {
    if (_isDisposed || _seekGeneration != seekGen || _client == null) return;
    if (_totalContentLength > 0 && _currentStreamOffset >= _totalContentLength) return;

    try {
      final req = await _client!.getUrl(_uri);
      if (_isDisposed || _seekGeneration != seekGen) return;
      _applyCommonHeaders(req);
      req.headers.set(HttpHeaders.rangeHeader, 'bytes=$_currentStreamOffset-');

      final res = await req.close();
      if (_isDisposed || _seekGeneration != seekGen) {
        try {
          res.drain<void>().ignore();
        } catch (_) {}
        return;
      }

      if (res.statusCode == 206) {
        _listenToResponse(res, seekGen);
      } else if (res.statusCode == 200) {
        _currentStreamOffset = 0;
        native.miniaudio_player_stream_flush(_player.handle, 0);
        _listenToResponse(res, seekGen);
      } else {
        _log(MapLogLevel.error, 'HTTP ${res.statusCode} (${res.reasonPhrase}) while reconnecting to $_uri');
        try {
          res.drain<void>().ignore();
        } catch (_) {}
        _onStreamError(
          MiniaudioPlayerException(
            'HTTP ${res.statusCode} (${res.reasonPhrase}) while reconnecting to $_uri',
            errorCode: res.statusCode,
          ),
        );
      }
    } catch (e) {
      if (_seekGeneration == seekGen && !_isDisposed) {
        _onStreamDone();
      }
    }
  }

  void _startBackpressureMonitor() {
    if (_isDisposed || _isStopped) return;
    if (_backpressureTimer != null && _backpressureTimer!.isActive) {
      return;
    }
    _backpressureTimer?.cancel();
    _backpressureTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (_isDisposed || _isStopped) {
        timer.cancel();
        return;
      }
      final statusPtr = calloc<native.miniaudio_stream_status_t>();
      try {
        if (native.miniaudio_player_stream_get_status(_player.handle, statusPtr) ==
            MapResult.success) {
          final fillPct = statusPtr.ref.fill_percentage;
          _readCursorByte = statusPtr.ref.read_cursor_byte;
          _rangeStart = statusPtr.ref.range_start;
          _rangeEnd = statusPtr.ref.range_end;
          final aheadHeadroomBytes = statusPtr.ref.range_end - statusPtr.ref.read_cursor_byte;
          _aheadHeadroomBytes = aheadHeadroomBytes;

          if (fillPct > 0.85 && _responseSub != null && !_responseSub!.isPaused) {
            _responseSub!.pause();
            _isPausedByBackpressure = true;
          } else if (fillPct < 0.40 && _responseSub != null && _responseSub!.isPaused && _isPausedByBackpressure) {
            _responseSub!.resume();
            _isPausedByBackpressure = false;
          }
        }
      } finally {
        calloc.free(statusPtr);
      }
    });
  }

  /// Handles seeking by using in-RAM cache when available, or opening a new HTTP Byte-Range connection.
  Future<void> seek(Duration position) async {
    if (_isDisposed) return;
    if (_isLive && _totalContentLength <= 0) {
      if (_isStopped) {
        _isStopped = false;
        _isStreamEnded = false;
        _isPausedByBackpressure = false;
        _prefetchTimer?.cancel();
        _prefetchTimer = null;
        _reconnectTimer?.cancel();
        _reconnectTimer = null;
        final thisSeekGen = ++_seekGeneration;
        _responseSub?.cancel();
        _responseSub = null;
        try {
          _currentIterator?.cancel();
        } catch (_) {}
        _currentIterator = null;

        _startBackpressureMonitor();

        final client = _ensureClient();
        try {
          final req = await client.getUrl(_uri);
          if (_isDisposed || _seekGeneration != thisSeekGen) {
            return;
          }
          _applyCommonHeaders(req);
          final res = await req.close();
          if (_isDisposed || _seekGeneration != thisSeekGen) {
            try {
              res.drain<void>().ignore();
            } catch (_) {}
            return;
          }
          if (res.statusCode >= 200 && res.statusCode < 300) {
            _currentStreamOffset = 0;
            native.miniaudio_player_stream_flush(_player.handle, 0);
            _listenToResponse(res, thisSeekGen);
          } else {
            try {
              res.drain<void>().ignore();
            } catch (_) {}
            _onStreamError(
              MiniaudioPlayerException(
                'HTTP ${res.statusCode} (${res.reasonPhrase}) while reconnecting to live stream $_uri',
                errorCode: res.statusCode,
              ),
            );
          }
        } catch (e) {
          if (!_isDisposed && _seekGeneration == thisSeekGen) {
            _onStreamError(e);
          }
        }
      } else {
        // In live streams with unknown total length, seek within circular buffer only
        native.miniaudio_player_seek(_player.handle, position.inMilliseconds);
      }
      return;
    }

    final durationMs = _player.state.duration.inMilliseconds;
    if (durationMs <= 0) return;

    var targetByte = native.miniaudio_player_stream_get_seek_byte(
      _player.handle,
      position.inMilliseconds,
    );
    final audioOffset = native.miniaudio_player_get_audio_data_offset(_player.handle);
    if (position <= Duration.zero && audioOffset > 0) {
      targetByte = audioOffset;
    } else if (targetByte < 0) {
      final audioStart = audioOffset > 0 ? audioOffset : 0;
      final audioBytes = _totalContentLength > audioStart ? (_totalContentLength - audioStart) : _totalContentLength;
      targetByte = audioStart + ((position.inMilliseconds * audioBytes) ~/ durationMs);
      targetByte = (targetByte ~/ 4) * 4;
    }
    if (targetByte >= _totalContentLength && _totalContentLength > 4) {
      targetByte = _totalContentLength - 4;
    }
    if (targetByte < 0) targetByte = 0;

    // Reset backpressure paused state on seek
    _isPausedByBackpressure = false;

    // Concurrency safety: increment seek generation, cancel active network streams,
    // and cancel any pending prefetch timer synchronously on ALL seeks (both Cache HIT and Cache MISS)
    // to prevent stale in-flight HTTP downloads from poisoning the buffer ranges or triggering false EOF.
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final thisSeekGen = ++_seekGeneration;
    _isStreamEnded = false;
    _isStopped = false;
    _responseSub?.cancel();
    _responseSub = null;
    try {
      _currentIterator?.cancel();
    } catch (_) {}
    _currentIterator = null;

    // Restart backpressure monitor on regular seeks
    _startBackpressureMonitor();

    // 1. Atomic native seek & cache evaluation
    final cacheRes = native.miniaudio_player_stream_seek(
      _player.handle,
      position.inMilliseconds,
      targetByte,
    );

    if (cacheRes == 1) {
      // In-RAM full cache HIT: audio was already buffered in sliding window or fully in pinned head
      return;
    }

    if (cacheRes == 2) {
      // Pinned Head cache HIT: audio is ready in RAM; seek returns immediately with 0 ms latency.
      _schedulePinnedHeadPrefetch(thisSeekGen);
      return;
    }

    // 2. Cache MISS (cacheRes == 0): reopen HTTP Byte-Range connection from targetByte
    try {
      final client = _ensureClient();
      HttpClientResponse? res;
      int seekRetries = 0;
      while (true) {
        final req = await client.getUrl(_uri);
        _applyCommonHeaders(req);
        req.headers.set(HttpHeaders.rangeHeader, 'bytes=$targetByte-');

        res = await req.close();
        if (_isDisposed || _seekGeneration != thisSeekGen) {
          try {
            res.drain<void>().ignore();
          } catch (_) {}
          return;
        }

        if ((res.statusCode == 429 || res.statusCode == 503) && seekRetries < 3) {
          seekRetries++;
          _log(MapLogLevel.warning, 'HTTP ${res.statusCode} (${res.reasonPhrase}) on seek to byte $targetByte on $_uri (retry $seekRetries/3)');
          try {
            await res.drain<void>();
          } catch (_) {}
          final retryAfter = int.tryParse(res.headers.value(HttpHeaders.retryAfterHeader) ?? '') ?? 1;
          await Future<void>.delayed(Duration(milliseconds: min(2000, max(500, retryAfter * 1000))));
          continue;
        }
        break;
      }

      if (res.statusCode == 200 || res.statusCode == 206) {
        if (res.statusCode == 206) {
          _currentStreamOffset = targetByte;
        } else {
          _currentStreamOffset = 0;
          native.miniaudio_player_stream_flush(_player.handle, 0);
        }
        _listenToResponse(res, thisSeekGen);
      } else {
        _log(MapLogLevel.error, 'HTTP ${res.statusCode} (${res.reasonPhrase}) on seek to byte $targetByte on $_uri');
        try {
          res.drain<void>().ignore();
        } catch (_) {}
        _onStreamError(
          MiniaudioPlayerException(
            'HTTP ${res.statusCode} (${res.reasonPhrase}) on seek to $_uri',
            errorCode: res.statusCode,
          ),
        );
      }
    } catch (e) {
      if (_isDisposed || _seekGeneration != thisSeekGen) {
        return;
      }
      _onStreamError(e);
    }
  }

  HttpClient _ensureClient() {
    return _client ??= HttpClient()
      ..userAgent = _defaultUserAgent
      ..autoUncompress = false;
  }

  void _schedulePinnedHeadPrefetch(int seekGen) {
    _prefetchTimer?.cancel();
    // 50ms debounce ensures seek(0) returns 0 immediate range requests,
    // and prevents network thrashing during rapid seeking
    _prefetchTimer = Timer(const Duration(milliseconds: 50), () async {
      if (_isDisposed || _seekGeneration != seekGen) {
        return;
      }
      _startBackpressureMonitor();

      int headSize = _pinnedHeadSize;
      try {
        final nativeHead =
            _miniaudioPlayerStreamGetPinnedHeadSize(_player.handle);
        if (nativeHead > 0) {
          headSize = nativeHead;
        }
      } catch (_) {}
      if (_totalContentLength > 0 && _totalContentLength < headSize) {
        headSize = _totalContentLength;
      }

      if (_totalContentLength > 0 && headSize >= _totalContentLength) {
        return;
      }

      try {
        final client = _ensureClient();
        final req = await client.getUrl(_uri);
        if (_isDisposed || _seekGeneration != seekGen) return;
        _applyCommonHeaders(req);

        if (_isRangeSupported) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$headSize-');
        }

        final res = await req.close();
        if (_isDisposed || _seekGeneration != seekGen) {
          try {
            res.drain<void>().ignore();
          } catch (_) {}
          return;
        }

        if (res.statusCode == 206) {
          _currentStreamOffset = headSize;
          _listenToResponse(res, seekGen);
        } else if (res.statusCode == 200) {
          _currentStreamOffset = 0;
          native.miniaudio_player_stream_flush(_player.handle, 0);
          _listenToResponse(res, seekGen);
        } else {
          _log(MapLogLevel.warning, 'HTTP ${res.statusCode} (${res.reasonPhrase}) on pinned head prefetch for $_uri');
          try {
            res.drain<void>().ignore();
          } catch (_) {}
        }
      } catch (e) {
        if (_seekGeneration == seekGen && !_isDisposed) {
          _onStreamError(e);
        }
      }
    });
  }

  /// Cancels in-flight network requests and prefetch timers, but preserves pinned head.
  Future<void> stop() async {
    _isStopped = true;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _backpressureTimer?.cancel();
    _backpressureTimer = null;
    _seekGeneration++;
    _responseSub?.cancel();
    _responseSub = null;
    try {
      _currentIterator?.cancel();
    } catch (_) {}
    _currentIterator = null;
    _disposeClient();
    _readCursorByte = 0;
    _currentStreamOffset = _pinnedHeadSize;
    _isPausedByBackpressure = false;
    _isStreamEnded = false;
  }

  /// Detects the miniaudio encoding format hint purely from magic bytes and MIME,
  /// avoiding file extensions or path matching.
  static int _detectEncodingFormat(List<int> bytes, String? contentType) {
    if (bytes.length >= 8) {
      // ftyp (MP4 / M4A / AAC / ALAC container)
      if (bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70) {
        return 0; // custom backend (miniaudio_aac / minimp4)
      }
    }
    if (bytes.length >= 4) {
      // RIFF (WAV)
      if (bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) {
        return 1; // ma_encoding_format_wav
      }
      // fLaC (FLAC)
      if (bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43) {
        return 2; // ma_encoding_format_flac
      }
      // ID3 or MP3 sync frame
      if ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0 && (bytes[1] & 0x06) != 0x00)) {
        return 3; // ma_encoding_format_mp3
      }
      // OggS (Vorbis or Opus)
      if (bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
        final probeStr = String.fromCharCodes(bytes.sublist(0, min(256, bytes.length)));
        if (probeStr.contains('OpusHead') || (contentType != null && contentType.toLowerCase().contains('opus'))) {
          return 0; // custom libopus decoder
        }
        return 4; // ma_encoding_format_vorbis
      }
    }

    final mime = (contentType ?? '').toLowerCase();
    if (mime.contains('audio/mp4') || mime.contains('audio/m4a') || mime.contains('audio/x-m4a') || mime.contains('audio/aac')) {
      return 0; // custom backend
    } else if (mime.contains('audio/mpeg') || mime.contains('audio/mp3')) {
      return 3; // ma_encoding_format_mp3
    } else if (mime.contains('audio/wav') || mime.contains('audio/x-wav')) {
      return 1; // ma_encoding_format_wav
    } else if (mime.contains('audio/flac')) {
      return 2; // ma_encoding_format_flac
    } else if (mime.contains('audio/opus')) {
      return 0; // custom libopus decoder
    } else if (mime.contains('audio/ogg') || mime.contains('audio/vorbis')) {
      return 4; // ma_encoding_format_vorbis
    }

    return 0; // unknown / auto-sniff in miniaudio
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _hasPinnedHead = false;
    _prefetchTimer?.cancel();
    _prefetchTimer = null;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _seekGeneration++;
    _backpressureTimer?.cancel();
    _backpressureTimer = null;
    _responseSub?.cancel();
    _responseSub = null;
    try {
      _currentIterator?.cancel();
    } catch (_) {}
    _currentIterator = null;
    if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
      _probeCompleter!.completeError(
        const MiniaudioPlayerException('Streamer disposed before probe completion'),
      );
    }
    _disposeClient();
  }

  void _applyCommonHeaders(HttpClientRequest req) {
    if (_headers != null) {
      _headers.forEach((k, v) => req.headers.set(k, v));
    }
    if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
      req.headers.set(HttpHeaders.userAgentHeader, _defaultUserAgent);
    }
    if (req.headers.value('Icy-MetaData') == null &&
        req.headers.value('icy-metadata') == null) {
      req.headers.set('Icy-MetaData', '1');
    }
  }

  StreamTransformer<List<int>, List<int>> _createIcyDemuxTransformer(
      int icyMetaint) {
    int remainingAudio = icyMetaint;
    int remainingMeta = 0;
    bool readingLength = false;
    final metaBuilder = BytesBuilder(copy: false);

    return StreamTransformer<List<int>, List<int>>.fromHandlers(
      handleData: (chunk, sink) {
        int offset = 0;
        while (offset < chunk.length) {
          if (remainingAudio > 0) {
            final takeAudio = min(remainingAudio, chunk.length - offset);
            sink.add(chunk.sublist(offset, offset + takeAudio));
            offset += takeAudio;
            remainingAudio -= takeAudio;
            if (remainingAudio == 0) {
              readingLength = true;
            }
          } else if (readingLength) {
            final l = chunk[offset++];
            readingLength = false;
            if (l > 0) {
              remainingMeta = l * 16;
              metaBuilder.clear();
            } else {
              remainingAudio = icyMetaint;
            }
          } else if (remainingMeta > 0) {
            final takeMeta = min(remainingMeta, chunk.length - offset);
            metaBuilder.add(chunk.sublist(offset, offset + takeMeta));
            offset += takeMeta;
            remainingMeta -= takeMeta;
            if (remainingMeta == 0) {
              final metaBytes = metaBuilder.takeBytes();
              _player.setIcyMeta(metaBytes);
              remainingAudio = icyMetaint;
            }
          }
        }
      },
      handleDone: (sink) => sink.close(),
      handleError: (error, stackTrace, sink) =>
          sink.addError(error, stackTrace),
    );
  }

  Future<void> _probeTailAsync() async {
    if (_isDisposed ||
        !_isRangeSupported ||
        _isLive ||
        _detectedCodec == AudioCodec.pcm ||
        _detectedCodec == AudioCodec.aac ||
        _detectedCodec == AudioCodec.alac ||
        _totalContentLength <= 65536) {
      return;
    }
    if (_isDisposed || _client == null) return;

    final tailSize = min(65536, _totalContentLength);
    final tailStart = _totalContentLength - tailSize;
    try {
      final req = await _client!.getUrl(_uri);
      _applyCommonHeaders(req);
      req.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$tailStart-${_totalContentLength - 1}',
      );
      final res = await req.close();
      if (res.statusCode == 206) {
        final tailBytes = await res
            .fold<BytesBuilder>(BytesBuilder(copy: false), (b, d) => b..add(d))
            .then((b) => b.takeBytes());
        if (!_isDisposed && tailBytes.isNotEmpty) {
          _player.probeTail(tailBytes, tailStart);
        }
      } else {
        if (res.statusCode == 429 || res.statusCode == 503) {
          _log(MapLogLevel.warning, 'HTTP ${res.statusCode} (${res.reasonPhrase}) on tail probe for $_uri');
        }
        try {
          res.drain<void>().ignore();
        } catch (_) {}
      }
    } catch (_) {
      // Ignored if network tail probe fails or interrupted; stream will fetch normally at EOF
    }
  }

  void _disposeClient() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}

@Native<Int64 Function(Pointer<native.miniaudio_player_t>)>(
  symbol: 'miniaudio_player_stream_get_pinned_head_size',
  isLeaf: true,
)
external int _miniaudioPlayerStreamGetPinnedHeadSize(
  Pointer<native.miniaudio_player_t> player,
);
