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

  bool _isDisposed = false;
  int _totalContentLength = -1;
  int _currentStreamOffset = 0;
  bool _isRangeSupported = false;
  int _seekGeneration = 0;
  bool _isPausedByBackpressure = false;
  bool _isStreamEnded = false;

  /// Whether HTTP Range requests are supported by the server.
  bool get isRangeSupported => _isRangeSupported;

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

    _client = HttpClient()
      ..userAgent = _defaultUserAgent
      ..autoUncompress = false;

    // 1. Send initial request
    final HttpClientResponse res;
    try {
      final req = await _client!.getUrl(_uri);
      if (_headers != null) {
        _headers.forEach((k, v) => req.headers.set(k, v));
      }
      if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
        req.headers.set(HttpHeaders.userAgentHeader, _defaultUserAgent);
      }
      req.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      res = await req.close();
    } catch (e) {
      _disposeClient();
      throw MiniaudioPlayerException(
        'Failed to connect to $_uri: $e',
        errorCode: MapResult.errorFileNotFound,
      );
    }

    if (res.statusCode >= 400) {
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
    var probeCompleter = Completer<void>();
    final initialBuilder = BytesBuilder(copy: false);
    var streamDone = false;

    _responseSub = res.listen(
      (chunk) async {
        if (!probeCompleter.isCompleted) {
          initialBuilder.add(chunk);
          if (initialBuilder.length >= targetProbeSize) {
            _responseSub?.pause();
            if (!probeCompleter.isCompleted) {
              probeCompleter.complete();
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
        if (!probeCompleter.isCompleted) {
          probeCompleter.completeError(err);
        } else if (_seekGeneration == 0) {
          _onStreamError(err);
        }
      },
      onDone: () {
        streamDone = true;
        if (!probeCompleter.isCompleted) {
          probeCompleter.complete();
        } else if (_seekGeneration == 0) {
          _onStreamDone();
        }
      },
      cancelOnError: true,
    );

    try {
      await probeCompleter.future;
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
      final encodingFormat = _detectEncodingFormat(probeBytes, contentType);

      final totalDuration = _bufferAhead + _bufferBehind;
      final nominalBitrate = _player.state.audioBitrate > 0 ? _player.state.audioBitrate : 256000;
      final bytesPerSec = nominalBitrate ~/ 8;
      int calculatedCap = (totalDuration.inMilliseconds * bytesPerSec) ~/ 1000;

      if (isLiveStream && MiniaudioPlayer.globalConfig.bufferSizeLiveStreamMB != null) {
        calculatedCap = MiniaudioPlayer.globalConfig.bufferSizeLiveStreamMB! * 1024 * 1024;
      } else if (!isLiveStream && MiniaudioPlayer.globalConfig.bufferSizeNetworkMB != null) {
        calculatedCap = MiniaudioPlayer.globalConfig.bufferSizeNetworkMB! * 1024 * 1024;
      }

      if (_totalContentLength > 0 && calculatedCap > 0 && _totalContentLength <= calculatedCap) {
        calculatedCap = max(calculatedCap, _totalContentLength + 65536);
      }
      final bufferCap = max(max(256 * 1024, probeBytes.length * 2), calculatedCap);

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

      if (openRes == MapResult.success) {
        break;
      }

      // If decode failed and we can buffer more for format detection (e.g. large ID3/OpusTags cover art)
      if (openRes == MapResult.errorDecodeFailed && !isLiveStream && !streamDone && targetProbeSize < 2 * 1024 * 1024) {
        targetProbeSize = min(targetProbeSize + 512 * 1024, 2 * 1024 * 1024);
        probeCompleter = Completer<void>();
        _responseSub?.resume();
        try {
          await probeCompleter.future;
        } catch (_) {
          break;
        }
        continue;
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

    _player.pollAndEmit(force: true);

    // 4. Set persistent track metadata for UI and seek inspection
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

    // 5. Start adaptive backpressure flow control and resume subscription if paused
    _startBackpressureMonitor();
    if (_responseSub != null && _responseSub!.isPaused && !_isPausedByBackpressure) {
      _responseSub!.resume();
    }
  }

  void _listenToResponse(HttpClientResponse res, int seekGen) {
    if (_isDisposed) return;
    _responseSub = res.listen(
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
          int retries = 0;
          while (!_isDisposed && _seekGeneration == seekGen && retries < 200) {
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
            retries++;
          }
        }

        if (feedRes == MapResult.success) {
          _currentStreamOffset += sliceLen;
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
    _isStreamEnded = true;
    // Signal end or error to C stream
    native.miniaudio_player_stream_end(_player.handle);
  }

  void _onStreamDone() {
    if (_isDisposed) return;
    _isStreamEnded = true;
    native.miniaudio_player_stream_end(_player.handle);
  }

  void _startBackpressureMonitor() {
    _backpressureTimer?.cancel();
    _backpressureTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_isDisposed) return;
      final statusPtr = calloc<native.miniaudio_stream_status_t>();
      try {
        if (native.miniaudio_player_stream_get_status(_player.handle, statusPtr) ==
            MapResult.success) {
          final fillPct = statusPtr.ref.fill_percentage;
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

    // Check if the seek position is already held within the buffered RAM window:
    final buffered = _player.state.bufferedRange;
    final isWithinBufferedWindow = buffered.end > buffered.start &&
        position >= buffered.start &&
        position <= buffered.end;

    // Check if entire audio file is retained in RAM:
    final isEntireFileCached = _isStreamEnded &&
        _totalContentLength > 0 &&
        buffered.start == Duration.zero &&
        buffered.streamPercentage >= 0.99;

    if (isWithinBufferedWindow || isEntireFileCached) {
      native.miniaudio_player_seek(_player.handle, position.inMilliseconds);
      _player.pollAndEmit(force: true);
      return;
    }

    if (_isLive || _totalContentLength <= 0) {
      // In live streams, seeking outside the circular buffer window cannot reach un-buffered future audio
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
    if (targetByte >= _totalContentLength) {
      targetByte = _totalContentLength - 4;
    }
    if (targetByte < 0) targetByte = 0;

    // Cancel current active response and any running iterator
    final thisSeekGen = ++_seekGeneration;
    _isStreamEnded = false;
    _responseSub?.cancel();
    _responseSub = null;
    try {
      await _currentIterator?.cancel();
    } catch (_) {}
    _currentIterator = null;

    // 1. Update native cursor to seek target
    native.miniaudio_player_seek(_player.handle, position.inMilliseconds);
    // 2. Flush native C stream to new byte offset and reset decoder
    native.miniaudio_player_stream_flush(_player.handle, targetByte);

    // 3. Reopen Range request
    final req = await _client!.getUrl(_uri);
    if (_headers != null) {
      _headers.forEach((k, v) => req.headers.set(k, v));
    }
    if (req.headers.value(HttpHeaders.userAgentHeader) == null) {
      req.headers.set(HttpHeaders.userAgentHeader, _defaultUserAgent);
    }
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$targetByte-');

    final res = await req.close();
    if (_isDisposed || _seekGeneration != thisSeekGen) {
      return;
    }


    if (res.statusCode == 200 || res.statusCode == 206) {
      if (res.statusCode == 206) {
        _currentStreamOffset = targetByte;
      } else {
        _currentStreamOffset = 0;
        native.miniaudio_player_stream_flush(_player.handle, 0);
      }
      _listenToResponse(res, thisSeekGen);
    }
  }

  /// Detects the miniaudio encoding format hint purely from magic bytes and MIME,
  /// avoiding file extensions or path matching.
  static int _detectEncodingFormat(List<int> bytes, String? contentType) {
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
    if (mime.contains('audio/mpeg') || mime.contains('audio/mp3')) {
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
    _seekGeneration++;
    _backpressureTimer?.cancel();
    _backpressureTimer = null;
    _responseSub?.cancel();
    _responseSub = null;
    try {
      _currentIterator?.cancel();
    } catch (_) {}
    _currentIterator = null;
    _disposeClient();
  }

  void _disposeClient() {
    try {
      _client?.close(force: true);
    } catch (_) {}
    _client = null;
  }
}
