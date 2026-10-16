import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/miniaudio_player.dart';
import '../api/player_exception.dart';
import '../ffi/native_types.dart';

/// Manages asynchronous HTTP/HTTPS progressive and live streaming for [MiniaudioPlayer].
///
/// Features:
/// - Progressive downloading with HTTP Byte-Range requests for arbitrary seeking.
/// - Adaptive backpressure flow control (pausing network download when C buffer is full).
/// - Live stream support with circular jitter buffer and infinite lifespan.
/// - Resilient error handling (HTTP status codes, connection drops, network timeouts).
class NetworkAudioStreamer {
  final MiniaudioPlayer _player;
  final Uri _uri;
  final Map<String, String>? _headers;
  final bool _isLive;
  final Duration _bufferAhead;

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

  /// Whether HTTP Range requests are supported by the server.
  bool get isRangeSupported => _isRangeSupported;

  /// Current byte offset reached in the network stream.
  int get currentStreamOffset => _currentStreamOffset;

  /// Total content length in bytes if advertised by the server, or -1.
  int get totalContentLength => _totalContentLength;

  /// Configured ahead-buffer duration.
  Duration get bufferAhead => _bufferAhead;

  NetworkAudioStreamer(
    this._player, {
    required Uri uri,
    Map<String, String>? headers,
    bool isLive = false,
    Duration bufferAhead = const Duration(seconds: 30),
  })  : _uri = uri,
        _headers = headers,
        _isLive = isLive,
        _bufferAhead = bufferAhead;

  /// Starts connecting to the remote audio URI, buffers initial frames,
  /// and configures the native streaming decoder.
  Future<void> start({bool autoPlay = false}) async {
    _player.ensureNotDisposed();

    _client = HttpClient()
      ..userAgent = 'miniaudio_player/6.0'
      ..autoUncompress = false;

    // 1. Send initial request
    final HttpClientResponse res;
    try {
      final req = await _client!.getUrl(_uri);
      if (_headers != null) {
        _headers.forEach((k, v) => req.headers.set(k, v));
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

    // 2. Format sniffing hint from MIME or extension
    final encodingFormat = _detectEncodingFormat(_uri.path, contentType);

    // 3. Pre-buffer initial chunk for format probing in C using subscription
    final initialCompleter = Completer<Uint8List>();
    final initialBuilder = BytesBuilder(copy: false);

    _responseSub = res.listen(
      (chunk) {
        if (!initialCompleter.isCompleted) {
          initialBuilder.add(chunk);
          if (initialBuilder.length >= 65536) {
            _responseSub?.pause();
            initialCompleter.complete(initialBuilder.takeBytes());
          }
        } else {
          _onChunkReceived(chunk);
        }
      },
      onError: (err) {
        if (!initialCompleter.isCompleted) {
          initialCompleter.completeError(err);
        } else {
          _onStreamError(err);
        }
      },
      onDone: () {
        if (!initialCompleter.isCompleted) {
          initialCompleter.complete(initialBuilder.takeBytes());
        } else {
          _onStreamDone();
        }
      },
      cancelOnError: true,
    );

    final Uint8List initialBytes;
    try {
      initialBytes = await initialCompleter.future;
    } catch (e) {
      _disposeClient();
      throw MiniaudioPlayerException(
        'Connection interrupted while buffering stream from $_uri: $e',
        errorCode: MapResult.errorGeneric,
      );
    }

    if (initialBytes.isEmpty) {
      _disposeClient();
      throw const MiniaudioPlayerException('Empty audio stream received');
    }

    _currentStreamOffset = initialBytes.length;

    // 4. Initialize native streaming engine
    final initPtr = malloc.allocate<Uint8>(initialBytes.length);
    initPtr.asTypedList(initialBytes.length).setAll(0, initialBytes);
    try {
      final openRes = native.miniaudio_player_open_stream(
        _player.handle,
        initPtr.cast(),
        initialBytes.length,
        isLiveStream ? -1 : _totalContentLength,
        isLiveStream ? 1 : 0,
        2 * 1024 * 1024, // 2MB internal ring buffer
        encodingFormat,
      );
      if (openRes != MapResult.success) {
        _disposeClient();
        throw MiniaudioPlayerException(
          'Failed to initialize native streaming engine: ${MapResult.describe(openRes)}',
          errorCode: openRes,
        );
      }
    } finally {
      malloc.free(initPtr);
    }

    if (autoPlay) {
      final playRes = native.miniaudio_player_play(_player.handle);
      if (playRes != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to start playback on autoPlay: ${MapResult.describe(playRes)}',
          errorCode: playRes,
        );
      }
    }

    _player.pollAndEmit(force: true);

    // 5. Start adaptive backpressure flow control and resume subscription if paused
    _startBackpressureMonitor();
    if (_responseSub != null && _responseSub!.isPaused) {
      _responseSub!.resume();
    }
  }

  void _listenToResponse(HttpClientResponse res) {
    if (_isDisposed) return;
    _responseSub = res.listen(
      _onChunkReceived,
      onError: _onStreamError,
      onDone: _onStreamDone,
      cancelOnError: true,
    );
  }

  void _onChunkReceived(List<int> chunk) async {
    if (_isDisposed) return;
    final ptr = malloc.allocate<Uint8>(chunk.length);
    try {
      ptr.asTypedList(chunk.length).setAll(0, chunk);
      var feedRes = native.miniaudio_player_stream_feed(
        _player.handle,
        ptr.cast(),
        chunk.length,
      );

      // Handle Buffer Full backpressure retry
      if (feedRes != MapResult.success) {
        _responseSub?.pause();
        _isPausedByBackpressure = true;

        // Bounded retry loop (up to 5 seconds)
        int retries = 0;
        while (!_isDisposed && retries < 100) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (_isDisposed) break;

          feedRes = native.miniaudio_player_stream_feed(
            _player.handle,
            ptr.cast(),
            chunk.length,
          );
          if (feedRes == MapResult.success) {
            break;
          }
          retries++;
        }
      }

      if (feedRes == MapResult.success) {
        _currentStreamOffset += chunk.length;
      }
    } finally {
      malloc.free(ptr);
    }
  }

  void _onStreamError(Object error) {
    if (_isDisposed) return;
    // Signal end or error to C stream
    native.miniaudio_player_stream_end(_player.handle);
  }

  void _onStreamDone() {
    if (_isDisposed) return;
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

  /// Handles seeking by opening a new HTTP Byte-Range connection.
  Future<void> seek(Duration position) async {
    if (_isDisposed || _isLive || _totalContentLength <= 0) return;

    final durationMs = _player.state.duration.inMilliseconds;
    if (durationMs <= 0) return;

    var targetByte = ((position.inMilliseconds * _totalContentLength) ~/ durationMs);
    targetByte = (targetByte ~/ 4) * 4;
    if (targetByte >= _totalContentLength) {
      targetByte = _totalContentLength - 4;
    }
    if (targetByte < 0) targetByte = 0;

    // Cancel current active response and any running iterator
    final thisSeekGen = ++_seekGeneration;
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
    req.headers.set(HttpHeaders.rangeHeader, 'bytes=$targetByte-');

    final res = await req.close();
    if (_isDisposed || _seekGeneration != thisSeekGen) {
      return;
    }

    if (res.statusCode == 200 || res.statusCode == 206) {
      _currentStreamOffset = targetByte;
      _listenToResponse(res);
    }
  }

  static int _detectEncodingFormat(String path, String? contentType) {
    final lower = path.toLowerCase();
    final mime = (contentType ?? '').toLowerCase();

    if (mime.contains('audio/mpeg') || lower.endsWith('.mp3')) {
      return 3; // ma_encoding_format_mp3
    } else if (mime.contains('audio/wav') || mime.contains('audio/x-wav') || lower.endsWith('.wav')) {
      return 1; // ma_encoding_format_wav
    } else if (mime.contains('audio/flac') || lower.endsWith('.flac')) {
      return 2; // ma_encoding_format_flac
    } else if (mime.contains('audio/ogg') || mime.contains('application/ogg') || lower.endsWith('.ogg')) {
      return 4; // ma_encoding_format_vorbis
    }
    return 0; // unknown / auto-sniff
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
