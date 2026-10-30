import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../api/miniaudio_player.dart';
import '../api/player_exception.dart';
import '../api/track_metadata.dart';
import 'audio_byte_provider.dart';

/// Deterministic Finite State Machine states for [UnifiedAudioLoader].
enum UnifiedLoaderState {
  idle,
  probingHead,
  streaming,
  pausedByBackpressure,
  seeking,
  completed,
  stopped,
  error,
  disposed,
}

/// Unified progressive and random-access audio loader driving the C tripartite
/// buffer (`map_buffer_t`) from any [AudioByteProvider] (`File`, `Memory`,
/// `Asset`, `Network`, `LiveStream`, or custom).
///
/// Operates with zero `Timer.periodic` polling: backpressure and cursor
/// telemetry are evaluated reactively on engine telemetry ticks and stream chunks.
class UnifiedAudioLoader {
  final MiniaudioPlayer _player;
  final AudioByteProvider provider;
  final Duration _bufferAhead;
  final Duration _bufferBehind;

  UnifiedLoaderState _state = UnifiedLoaderState.idle;
  StreamSubscription<Uint8List>? _responseSub;
  Completer<void>? _probeCompleter;
  Timer? _reconnectTimer;

  int _seekGeneration = 0;
  int _reconnectRetries = 0;
  static const int _maxReconnectRetries = 5;

  int _totalContentLength = -1;
  int _currentStreamOffset = 0;
  bool _isRangeSupported = false;
  bool _isLive = false;
  bool _isPausedByBackpressure = false;
  int _pausedAtHeadroomBytes = 0;
  bool _isFeedingChunk = false;
  bool _isStreamEnded = false;
  bool _isStopped = false;
  bool _isDisposed = false;
  bool _isReopening = false;

  void _pauseSubscription() {
    final sub = _responseSub;
    if (sub != null && !sub.isPaused) {
      sub.pause();
    }
  }

  void _resumeSubscription() {
    final sub = _responseSub;
    if (sub == null) return;
    while (sub.isPaused) {
      sub.resume();
    }
  }

  int _readCursorByte = 0;
  int _rangeStart = 0;
  int _rangeEnd = 0;
  int _aheadHeadroomBytes = 0;
  AudioCodec _detectedCodec = AudioCodec.unknown;

  UnifiedAudioLoader(
    this._player, {
    required this.provider,
    Duration bufferAhead = const Duration(seconds: 30),
    Duration bufferBehind = const Duration(seconds: 10),
  })  : _bufferAhead = bufferAhead,
        _bufferBehind = bufferBehind {
    _isLive = provider.isLiveStream;
  }

  /// Current FSM state of the loader.
  UnifiedLoaderState get state => _state;

  void _refreshTelemetryFromBackend() {
    if (_isDisposed || _player.isDisposed) return;
    final status = _player.backend.getStreamStatus();
    if (status != null) {
      if (!_isStopped) {
        _readCursorByte = status.readCursorByte;
      }
      _rangeStart = status.rangeStart;
      _rangeEnd = status.rangeEnd;
      _aheadHeadroomBytes = status.aheadHeadroomBytes;
    }
  }

  /// Current byte offset reached in the decoder read cursor.
  int get readCursorByte {
    if (_isStopped) return 0;
    _refreshTelemetryFromBackend();
    return _readCursorByte;
  }

  /// Earliest continuous byte offset held in the native ring buffer.
  int get rangeStart {
    _refreshTelemetryFromBackend();
    return _rangeStart;
  }

  /// Furthest continuous byte offset held in the native ring buffer.
  int get rangeEnd {
    _refreshTelemetryFromBackend();
    return _rangeEnd;
  }

  /// Lookahead forward headroom in bytes ahead of the reading cursor.
  int get aheadHeadroomBytes {
    _refreshTelemetryFromBackend();
    return _aheadHeadroomBytes;
  }

  /// Whether random-access range requests are supported by the underlying provider.
  bool get isRangeSupported => _isRangeSupported;

  /// Current byte offset reached in the sequential provider stream.
  int get currentStreamOffset => _currentStreamOffset;

  /// Total content length in bytes if known, or -1.
  int get totalContentLength => _totalContentLength;

  /// Configured ahead-buffer duration.
  Duration get bufferAhead => _bufferAhead;

  /// Configured behind-buffer duration retained in circular RAM cache.
  Duration get bufferBehind => _bufferBehind;

  /// Whether the provider stream has completed (reached EOF).
  bool get isStreamEnded => _isStreamEnded;

  /// Whether the loader is currently stopped via [stop].
  bool get isStopped => _isStopped;

  /// Whether reactive backpressure management is currently active.
  bool get isBackpressureActive =>
      !_isDisposed &&
      !_isStopped &&
      _state != UnifiedLoaderState.idle &&
      _state != UnifiedLoaderState.stopped &&
      _state != UnifiedLoaderState.error &&
      _state != UnifiedLoaderState.disposed;

  void _log(int level, String message) {
    if (MiniaudioPlayer.globalConfig.logLevel.value >= level) {
      final tag = switch (level) {
        1 => 'ERROR',
        2 => 'WARN',
        3 => 'INFO',
        4 => 'DEBUG',
        5 => 'VERBOSE',
        _ => 'LOG',
      };
      // ignore: avoid_print
      print('[miniaudio_player][$tag][loader] $message');
    }
  }

  /// Opens the [provider] from byte 0, probes container boundaries and metadata,
  /// initializes the C tripartite buffer and decoder, and begins reactive streaming.
  Future<void> start() async {
    _player.ensureNotDisposed();
    _state = UnifiedLoaderState.probingHead;
    _isStreamEnded = false;
    _isStopped = false;
    _isPausedByBackpressure = false;
    final int gen = ++_seekGeneration;

    final AudioByteStreamResponse res = await provider.open(offset: 0);
    if (_isDisposed || _seekGeneration != gen) {
      await provider.close();
      return;
    }

    _totalContentLength = res.totalBytes;
    _isRangeSupported = res.isSeekable;
    _isLive = provider.isLiveStream || res.isLive || _totalContentLength <= 0;
    final String? contentType = res.contentType;

    final effectiveAhead = (_isLive && !provider.isLiveStream)
        ? Duration(milliseconds: min(_bufferAhead.inMilliseconds, 8000))
        : _bufferAhead;
    final effectiveBehind = (_isLive && !provider.isLiveStream)
        ? Duration.zero
        : _bufferBehind;
    final totalDuration = effectiveAhead + effectiveBehind;
    final nominalBitrate =
        _player.state.bitrate > 0 ? _player.state.bitrate : 256000;
    final bytesPerSec = max(1, nominalBitrate ~/ 8);
    int calculatedCap = (totalDuration.inMilliseconds * bytesPerSec) ~/ 1000;
    if (provider.isNetwork) {
      calculatedCap = max(calculatedCap, 2 * 1024 * 1024);
    }
    if (!provider.isNetwork &&
        !_isLive &&
        _totalContentLength > 0 &&
        totalDuration >= const Duration(seconds: 5) &&
        _totalContentLength <= 32 * 1024 * 1024) {
      calculatedCap = max(calculatedCap, _totalContentLength);
    }

    int targetProbeSize = (_totalContentLength > 0 && _totalContentLength < 65536)
        ? _totalContentLength
        : 65536;

    _probeCompleter = Completer<void>();
    final initialBuilder = BytesBuilder(copy: false);
    bool streamDone = false;
    bool id3Checked = false;

    _responseSub = res.stream.listen(
      (chunk) async {
        if (_state == UnifiedLoaderState.probingHead) {
          initialBuilder.add(chunk);
          // Auto-extend initial probe if an ID3v2 header larger than targetProbeSize is detected
          if (!id3Checked && initialBuilder.length >= 10) {
            id3Checked = true;
            final curBytes =
                chunk.length >= 10 ? chunk : initialBuilder.toBytes();
            if (curBytes[0] == 0x49 &&
                curBytes[1] == 0x44 &&
                curBytes[2] == 0x33) {
              final id3Size = 10 +
                  (((curBytes[6] & 0x7F) << 21) |
                      ((curBytes[7] & 0x7F) << 14) |
                      ((curBytes[8] & 0x7F) << 7) |
                      (curBytes[9] & 0x7F));
              if (id3Size + 16384 > targetProbeSize) {
                final needed = _totalContentLength > 0
                    ? min(_totalContentLength, id3Size + 65536)
                    : id3Size + 65536;
                if (needed > targetProbeSize && needed <= 16 * 1024 * 1024) {
                  targetProbeSize = needed;
                }
              }
            }
          }
          if (initialBuilder.length >= targetProbeSize) {
            _pauseSubscription();
            final pc = _probeCompleter;
            if (pc != null && !pc.isCompleted) {
              pc.complete();
            }
          }
        } else {
          _pauseSubscription();
          _isFeedingChunk = true;
          try {
            await _feedChunk(chunk, gen);
          } finally {
            _isFeedingChunk = false;
            if (!_isDisposed &&
                !_isStopped &&
                _seekGeneration == gen &&
                _responseSub != null &&
                !_isPausedByBackpressure) {
              _resumeSubscription();
            }
          }
        }
      },
      onError: (Object err) {
        final pc = _probeCompleter;
        if (pc != null && !pc.isCompleted) {
          pc.completeError(err);
        } else if (_seekGeneration == gen) {
          _onStreamError(err);
        }
      },
      onDone: () {
        streamDone = true;
        final pc = _probeCompleter;
        if (pc != null && !pc.isCompleted) {
          if (_totalContentLength > 0 &&
              initialBuilder.length < _totalContentLength &&
              initialBuilder.length < targetProbeSize) {
            pc.completeError(
              const MiniaudioPlayerException(
                'Premature EOF during buffering',
                errorCode: MapResult.errorGeneric,
              ),
            );
          } else {
            pc.complete();
          }
        } else if (_seekGeneration == gen) {
          _onStreamDone();
        }
      },
      cancelOnError: true,
    );

    try {
      await _probeCompleter!.future;
    } catch (e) {
      _state = UnifiedLoaderState.error;
      await _cancelActiveStream(closeProvider: true);
      throw MiniaudioPlayerException(
        'Connection interrupted while buffering stream from ${provider.sourceId}: $e',
        errorCode: MapResult.errorGeneric,
      );
    }

    if (initialBuilder.isEmpty) {
      _state = UnifiedLoaderState.error;
      await _cancelActiveStream(closeProvider: true);
      throw const MiniaudioPlayerException(
        'Empty audio stream received',
        errorCode: MapResult.errorDecodeFailed,
      );
    }

    int openRes = MapResult.errorGeneric;
    AudioCodec detectedCodec = AudioCodec.unknown;
    bool tailAlreadyProbed = false;
    Uint8List? preOpenTailBytes;

    while (!_isDisposed && _seekGeneration == gen) {
      final probeBytes = initialBuilder.toBytes();
      _currentStreamOffset = probeBytes.length;
      detectedCodec = AudioCodec.detect(probeBytes, mime: contentType);
      _detectedCodec = detectedCodec;
      final encodingFormat = _detectEncodingFormat(probeBytes, contentType);

      int effectiveBytesPerSec = bytesPerSec;
      if (detectedCodec == AudioCodec.pcm && probeBytes.length >= 32) {
        final wavByteRate = probeBytes[28] |
            (probeBytes[29] << 8) |
            (probeBytes[30] << 16) |
            (probeBytes[31] << 24);
        if (wavByteRate >= 8000 && wavByteRate <= 8 * 1024 * 1024) {
          effectiveBytesPerSec = wavByteRate;
        } else {
          effectiveBytesPerSec = 176 * 1024;
        }
      } else if (detectedCodec == AudioCodec.flac ||
          detectedCodec == AudioCodec.alac ||
          detectedCodec == AudioCodec.pcm) {
        effectiveBytesPerSec = 176 * 1024;
      }
      final int codecCap =
          (totalDuration.inMilliseconds * effectiveBytesPerSec) ~/ 1000;
      int bufferCap = max(256 * 1024, max(calculatedCap, codecCap));
      if (!_isLive &&
          _totalContentLength > 0 &&
          _totalContentLength <= max(calculatedCap, codecCap)) {
        bufferCap = max(bufferCap, _totalContentLength);
      }

      final isMp4 = probeBytes.length >= 8 &&
          probeBytes[4] == 0x66 &&
          probeBytes[5] == 0x74 &&
          probeBytes[6] == 0x79 &&
          probeBytes[7] == 0x70;
      final isOgg = probeBytes.length >= 4 &&
          probeBytes[0] == 0x4F &&
          probeBytes[1] == 0x67 &&
          probeBytes[2] == 0x67 &&
          probeBytes[3] == 0x53;

      if (isOgg &&
          !tailAlreadyProbed &&
          !_isLive &&
          _totalContentLength > probeBytes.length) {
        final tailSize = min(65536, _totalContentLength - probeBytes.length);
        final tailStart = _totalContentLength - tailSize;
        preOpenTailBytes = await provider.probeTail(tailStart, tailSize);
        if (preOpenTailBytes != null && preOpenTailBytes.isNotEmpty) {
          tailAlreadyProbed = true;
          _isRangeSupported = true;
        }
      }

      openRes = await _player.backend.openStreamEx(
        initialBytes: probeBytes,
        tailBytes: preOpenTailBytes,
        totalSize: _isLive ? -1 : _totalContentLength,
        isLive: _isLive,
        bufferCapacityBytes: bufferCap,
        encodingFormat: encodingFormat,
      );

      // If MP4 container failed format probing (non-faststart with 'moov' atom at EOF),
      // probe the last 256 KB via provider.probeTail().
      if (openRes == MapResult.errorDecodeFailed &&
          isMp4 &&
          !_isLive &&
          _totalContentLength > probeBytes.length) {
        final tailSize = min(256 * 1024, _totalContentLength - probeBytes.length);
        final tailStart = _totalContentLength - tailSize;
        final tailBytes = await provider.probeTail(tailStart, tailSize);
        if (tailBytes != null && tailBytes.isNotEmpty) {
          tailAlreadyProbed = true;
          _isRangeSupported = true;
          openRes = await _player.backend.openStreamEx(
            initialBytes: probeBytes,
            tailBytes: tailBytes,
            totalSize: _totalContentLength,
            isLive: false,
            bufferCapacityBytes: bufferCap,
            encodingFormat: encodingFormat,
          );
        }
      }

      if (openRes == MapResult.success) {
        final detectedAudioOffset = _player.backend.getAudioDataOffset();
        if (detectedAudioOffset > probeBytes.length &&
            !_isLive &&
            !streamDone) {
          final maxProbe = (_totalContentLength > 0 &&
                  _totalContentLength <= 16 * 1024 * 1024)
              ? _totalContentLength
              : 16 * 1024 * 1024;
          if (targetProbeSize < maxProbe &&
              probeBytes.length < detectedAudioOffset) {
            targetProbeSize = min(
              max(detectedAudioOffset + 65536, targetProbeSize + 1024 * 1024),
              maxProbe,
            );
            _probeCompleter = Completer<void>();
            _resumeSubscription();
            try {
              await _probeCompleter!.future;
            } catch (_) {
              break;
            }
            continue;
          }
        }

        if ((!_isLive &&
                _totalContentLength > 0 &&
                probeBytes.length >= _totalContentLength) ||
            (streamDone && (!_isLive || !provider.isNetwork) && _totalContentLength <= 0)) {
          _isStreamEnded = true;
          _player.backend.streamEnd();
        } else if (streamDone && provider.isNetwork) {
          _responseSub = null;
          _scheduleReconnect(gen, isLive: _isLive);
        }
        break;
      }

      if (openRes == MapResult.errorDecodeFailed && !_isLive && !streamDone) {
        final maxProbe = (_totalContentLength > 0 &&
                _totalContentLength <= 16 * 1024 * 1024)
            ? _totalContentLength
            : 8 * 1024 * 1024;
        if (targetProbeSize < maxProbe) {
          targetProbeSize = min(targetProbeSize + 512 * 1024, maxProbe);
          _probeCompleter = Completer<void>();
          _resumeSubscription();
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
      _state = UnifiedLoaderState.error;
      await _cancelActiveStream(closeProvider: true);
      throw MiniaudioPlayerException(
        'Failed to initialize audio engine for ${provider.sourceId}: ${MapResult.describe(openRes)}',
        errorCode: openRes,
      );
    }

    // If the file was not completely loaded in initialBytes and supports random-access tail probing,
    // probe the last 64 KB to extract trailing tags (ID3v1, APEv2, WAV LIST) and Ogg EOS duration.
    if (!_isStreamEnded &&
        !tailAlreadyProbed &&
        _isRangeSupported &&
        !_isLive &&
        _totalContentLength > _currentStreamOffset &&
        _detectedCodec != AudioCodec.aac &&
        _detectedCodec != AudioCodec.alac) {
      await _probeTailMetadata();
    }

    _refreshTelemetryFromBackend();

    final audioDataOffset = _player.backend.getAudioDataOffset();
    final trackMeta = AudioTrackMetadata(
      codec: detectedCodec,
      format: AudioFormat.fromCodec(detectedCodec),
      formatName: detectedCodec.name,
      duration: _player.state.duration,
      totalBytes: _totalContentLength > 0 ? _totalContentLength : 0,
      bitrate: _player.state.bitrate,
      sampleRate: _player.sampleRate,
      channels: _player.channels,
      isNetwork: provider.isNetwork,
      isLiveStream: _isLive,
      uri: provider.uri,
      audioDataOffset: audioDataOffset > 0 ? audioDataOffset : 0,
    );
    _player.setTrackMetadata(trackMeta);
    _player.checkMetaBytesUpdated();

    if (_isStreamEnded) {
      _state = UnifiedLoaderState.completed;
      await _cancelActiveStream();
    } else {
      _state = UnifiedLoaderState.streaming;
      onEngineTelemetryTick();
      if (_responseSub != null &&
          _responseSub!.isPaused &&
          !_isPausedByBackpressure) {
        _resumeSubscription();
      }
    }
  }

  Future<void> _probeTailMetadata() async {
    if (_isDisposed || _isLive || _totalContentLength <= 0) {
      return;
    }
    final tailSize = min(65536, _totalContentLength);
    final tailStart = _totalContentLength - tailSize;
    final tailBytes = await provider.probeTail(tailStart, tailSize);
    if (!_isDisposed && tailBytes != null && tailBytes.isNotEmpty) {
      _isRangeSupported = true;
      _player.probeTail(tailBytes, tailStart);
    }
  }

  /// Reactively evaluates C tripartite buffer fill and backpressure without any `Timer.periodic`.
  /// Invoked by [MiniaudioPlayer] on engine telemetry events (`onPosition`, `onBufferedRange`,
  /// `onBuffering`, `onState`) and after feeding chunks.
  void onEngineTelemetryTick() {
    if (_isDisposed ||
        _isStopped ||
        _isReopening ||
        _player.isDisposed ||
        _state == UnifiedLoaderState.idle ||
        _state == UnifiedLoaderState.probingHead ||
        _state == UnifiedLoaderState.seeking ||
        _state == UnifiedLoaderState.completed) {
      return;
    }
    final status = _player.backend.getStreamStatus();
    if (status == null) return;

    _player.notifyBuffering(status.isBuffering);
    _readCursorByte = status.readCursorByte;
    _rangeStart = status.rangeStart;
    _rangeEnd = status.rangeEnd;
    _aheadHeadroomBytes = status.aheadHeadroomBytes;

    final nominalBitrate =
        _player.state.bitrate > 0 ? _player.state.bitrate : 256000;
    final bytesPerSec = max(1, nominalBitrate ~/ 8);
    final targetAheadBytes = max(
      _isLive ? 512 * 1024 : 256 * 1024,
      (_bufferAhead.inMilliseconds * bytesPerSec) ~/ 1000,
    );
    final capBytes = status.bufferCapacity > 0
        ? status.bufferCapacity
        : 4 * 1024 * 1024;
    // When playing a live stream, audio is produced at realtime 1.0x rate.
    // We only apply backpressure if buffer approaches full capacity (90%) to prevent eviction.
    // When paused, we apply backpressure at targetAheadBytes to prevent buffer overflow.
    final maxAheadBytes = (_isLive && _player.state.playing)
        ? (capBytes * 0.90).round()
        : min((capBytes * 0.85).round(), targetAheadBytes);

    final releaseThreshold = (_isLive && _player.state.playing)
        ? (capBytes * 0.70).round()
        : (maxAheadBytes * 0.60).round();

    if (_aheadHeadroomBytes >= maxAheadBytes &&
        _aheadHeadroomBytes > 0 &&
        _responseSub != null &&
        !_isPausedByBackpressure) {
      _pauseSubscription();
      _isPausedByBackpressure = true;
      _pausedAtHeadroomBytes = _aheadHeadroomBytes;
      _state = UnifiedLoaderState.pausedByBackpressure;
      _log(5, 'Backpressure engaged: headroom=$_aheadHeadroomBytes >= $maxAheadBytes (live=$_isLive)');
    } else if (_aheadHeadroomBytes < releaseThreshold ||
        (_isPausedByBackpressure &&
            _pausedAtHeadroomBytes > 0 &&
            _aheadHeadroomBytes <= (_pausedAtHeadroomBytes * 0.75).round()) ||
        status.isBuffering) {
      if (_responseSub != null &&
          (_isPausedByBackpressure || _responseSub!.isPaused)) {
        _isPausedByBackpressure = false;
        _pausedAtHeadroomBytes = 0;
        _state = UnifiedLoaderState.streaming;
        if (!_isFeedingChunk) {
          _resumeSubscription();
        }
        _log(5, 'Backpressure released: headroom=$_aheadHeadroomBytes (live=$_isLive)');
      } else if (_responseSub == null &&
          !_isReopening &&
          _reconnectTimer == null &&
          !_isStreamEnded &&
          !_isStopped &&
          provider.isNetwork) {
        if (!_isLive && _totalContentLength > 0 && _rangeEnd < _totalContentLength && _isRangeSupported) {
          _isPausedByBackpressure = false;
          _pausedAtHeadroomBytes = 0;
          _state = UnifiedLoaderState.streaming;
          _reconnectRetries = 0;
          _currentStreamOffset = _rangeEnd;
          _reopenFromOffset(_rangeEnd, _seekGeneration);
        } else if (_isLive) {
          _isPausedByBackpressure = false;
          _pausedAtHeadroomBytes = 0;
          _state = UnifiedLoaderState.streaming;
          _log(4, 'Live stream idle/disconnected while buffering/playing; reconnecting');
          _scheduleReconnect(_seekGeneration, isLive: true);
        }
      }
    }
  }

  Future<void> _feedChunk(Uint8List chunk, int seekGen) async {
    if (_isDisposed || _seekGeneration != seekGen) return;

    const int sliceSize = 32768; // 32 KB slices
    int offset = 0;
    while (!_isDisposed && _seekGeneration == seekGen && offset < chunk.length) {
      final nominalBitrate =
          _player.state.bitrate > 0 ? _player.state.bitrate : 256000;
      final bytesPerSec = max(1, nominalBitrate ~/ 8);
      final targetAheadBytes = max(
        _isLive ? 512 * 1024 : 256 * 1024,
        (_bufferAhead.inMilliseconds * bytesPerSec) ~/ 1000,
      );
      final capBytes = _player.backend.getStreamStatus()?.bufferCapacity ??
          (4 * 1024 * 1024);
      final maxAheadBytes = (_isLive && _player.state.playing)
          ? (capBytes * 0.90).round()
          : min((capBytes * 0.85).round(), targetAheadBytes);

      final releaseThreshold = (_isLive && _player.state.playing)
          ? (capBytes * 0.70).round()
          : (maxAheadBytes * 0.60).round();

      if (_aheadHeadroomBytes >= maxAheadBytes && _aheadHeadroomBytes > 0) {
        _pauseSubscription();
        _isPausedByBackpressure = true;
        _pausedAtHeadroomBytes = _aheadHeadroomBytes;
        _state = UnifiedLoaderState.pausedByBackpressure;
        _log(5, '_feedChunk backpressure pause: headroom=$_aheadHeadroomBytes >= $maxAheadBytes (live=$_isLive)');
        while (!_isDisposed && !_isStopped && _seekGeneration == seekGen) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (_isDisposed || _isStopped || _seekGeneration != seekGen) return;
          onEngineTelemetryTick();
          if (!_isPausedByBackpressure ||
              _aheadHeadroomBytes < releaseThreshold ||
              (_isLive && _player.state.playing && _aheadHeadroomBytes < (capBytes * 0.85).round())) {
            _log(5, '_feedChunk backpressure release: headroom=$_aheadHeadroomBytes');
            break;
          }
        }
      }

      final int end =
          (offset + sliceSize < chunk.length) ? offset + sliceSize : chunk.length;
      final Uint8List slice = Uint8List.sublistView(chunk, offset, end);

      int feedRes = _player.backend.streamFeed(slice);
      if (feedRes == MapResult.errorBusy) {
        _pauseSubscription();
        _isPausedByBackpressure = true;
        _state = UnifiedLoaderState.pausedByBackpressure;
        _log(5, '_feedChunk errorBusy: pausing subscription and retrying');
        while (!_isDisposed && !_isStopped && _seekGeneration == seekGen) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
          if (_isDisposed || _isStopped || _seekGeneration != seekGen) return;
          feedRes = _player.backend.streamFeed(slice);
          if (feedRes == MapResult.success) {
            _isPausedByBackpressure = false;
            _state = UnifiedLoaderState.streaming;
            _log(5, '_feedChunk errorBusy resolved; resumed streaming');
            break;
          }
        }
      }

      if (feedRes == MapResult.success) {
        _reconnectRetries = 0;
        _currentStreamOffset += slice.length;
        offset = end;
        onEngineTelemetryTick();
      } else {
        break;
      }
    }
  }

  void _attachStream(Stream<Uint8List> stream, int seekGen) {
    if (_isDisposed || _seekGeneration != seekGen) return;
    _state = UnifiedLoaderState.streaming;
    _responseSub = stream.listen(
      (chunk) async {
        _pauseSubscription();
        _isFeedingChunk = true;
        try {
          await _feedChunk(chunk, seekGen);
        } finally {
          _isFeedingChunk = false;
          if (!_isDisposed &&
              !_isStopped &&
              _seekGeneration == seekGen &&
              _responseSub != null &&
              !_isPausedByBackpressure) {
            _resumeSubscription();
          }
        }
      },
      onError: (Object err) {
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

  void _onStreamError(Object error) {
    if (_isDisposed || _isStopped) return;
    _responseSub = null;
    _player.notifyBuffering(false);
    _log(1, 'Stream error on ${provider.sourceId}: $error');
    if (_isLive || _totalContentLength <= 0) {
      _scheduleReconnect(_seekGeneration, isLive: true);
      return;
    }
    if (_isRangeSupported &&
        _totalContentLength > 0 &&
        _currentStreamOffset < _totalContentLength &&
        _reconnectRetries < _maxReconnectRetries) {
      _scheduleReconnect(_seekGeneration, isLive: false);
      return;
    }
    _isStreamEnded = true;
    _state = UnifiedLoaderState.completed;
    _player.backend.streamEnd();
  }

  void _onStreamDone() {
    if (_isDisposed || _isStopped) return;
    _responseSub = null;
    if ((_isLive || _totalContentLength <= 0) && provider.isNetwork) {
      _scheduleReconnect(_seekGeneration, isLive: true);
      return;
    }
    if (_totalContentLength > 0 && _currentStreamOffset < _totalContentLength) {
      if (_isPausedByBackpressure && _isRangeSupported) {
        // Server closed idle connection while paused by backpressure;
        // onEngineTelemetryTick() will reopen via Range when headroom drops below 82%.
        return;
      }
      if (_isRangeSupported && _reconnectRetries < _maxReconnectRetries) {
        _scheduleReconnect(_seekGeneration, isLive: false);
        return;
      }
      return;
    }
    _isStreamEnded = true;
    _state = UnifiedLoaderState.completed;
    _player.backend.streamEnd();
    _player.checkMetaBytesUpdated();
  }

  void _scheduleReconnect(int seekGen, {required bool isLive}) {
    if (_isDisposed || _isStopped || _seekGeneration != seekGen) return;
    final int delayMs = isLive
        ? (250 * (1 << min(4, _reconnectRetries))).clamp(250, 3000)
        : (100 * (1 << min(4, _reconnectRetries))).clamp(100, 2000);
    _reconnectRetries++;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_isDisposed || _isStopped || _seekGeneration != seekGen) return;
      _reopenFromOffset(isLive ? 0 : _currentStreamOffset, seekGen);
    });
  }

  Future<void> _reopenFromOffset(int targetByte, int seekGen) async {
    if (_isDisposed || _isStopped || _seekGeneration != seekGen) return;
    _isReopening = true;
    try {
      final res = await provider.open(offset: targetByte);
      if (_isDisposed || _isStopped || _seekGeneration != seekGen) {
        if (_isDisposed) {
          await provider.close();
        } else {
          await provider.abortActiveStream();
        }
        return;
      }
      if (_isLive) {
        _currentStreamOffset = 0;
        _player.backend.streamFlush(0);
      } else {
        _currentStreamOffset = targetByte;
      }
      _attachStream(res.stream, seekGen);
    } catch (e) {
      if (!_isDisposed && !_isStopped && _seekGeneration == seekGen) {
        _onStreamError(e);
      }
    } finally {
      if (_seekGeneration == seekGen) {
        _isReopening = false;
      }
    }
  }

  /// Notifies the loader that playback has been resumed via `play()`.
  void onPlay() {
    if (_isDisposed || _isStopped) return;
    _refreshTelemetryFromBackend();
    _log(4, 'onPlay: live=$_isLive, state=$_state, readCursor=$_readCursorByte, range=[$_rangeStart..$_rangeEnd], headroom=$_aheadHeadroomBytes');
    if (_isLive) {
      final status = _player.backend.getStreamStatus();
      final bool isStarvedOrEvicted = status != null &&
          (status.readCursorByte < status.rangeStart ||
           (status.rangeEnd > 0 && status.readCursorByte >= status.rangeEnd));

      if ((isStarvedOrEvicted || _responseSub == null) &&
          !_isReopening &&
          _reconnectTimer == null &&
          provider.isNetwork) {
        _log(3, 'onPlay: live stream starved/evicted or disconnected; reconnecting immediately');
        _scheduleReconnect(_seekGeneration, isLive: true);
      } else {
        // Proactively unpause backpressure and resume streaming on play
        _isPausedByBackpressure = false;
        _pausedAtHeadroomBytes = 0;
        _state = UnifiedLoaderState.streaming;
        if (_responseSub != null && _responseSub!.isPaused) {
          _resumeSubscription();
          _log(4, 'onPlay: proactively resumed network subscription');
        }
      }
    } else {
      if (_isPausedByBackpressure) {
        _isPausedByBackpressure = false;
        _pausedAtHeadroomBytes = 0;
        _state = UnifiedLoaderState.streaming;
        if (_responseSub != null && _responseSub!.isPaused && !_isFeedingChunk) {
          _resumeSubscription();
        }
      }
    }
    onEngineTelemetryTick();
  }

  /// Notifies the loader that playback has been paused via `pause()`.
  void onPause() {
    if (_isDisposed || _isStopped) return;
    _refreshTelemetryFromBackend();
    _log(4, 'onPause: live=$_isLive, state=$_state, readCursor=$_readCursorByte, range=[$_rangeStart..$_rangeEnd], headroom=$_aheadHeadroomBytes');
  }

  /// Resumes loader activity when `play()` is called after `stop()`.
  ///
  /// Preserves cached `HEAD`, `RING`, and `TAIL` data in C: if the audio start
  /// offset is still in `RING`, playback starts instantaneously with 0 network
  /// latency; if `stop()` had interrupted an incomplete download, background
  /// streaming resumes from `rangeEnd`.
  Future<void> onPlayFromStopped() async {
    if (_isDisposed || !_isStopped) return;
    _isStopped = false;

    if (_isLive) {
      _isStreamEnded = false;
      _isPausedByBackpressure = false;
      final int thisSeekGen = ++_seekGeneration;
      await _cancelActiveStream();
      await _reopenFromOffset(0, thisSeekGen);
      return;
    }

    final status = _player.backend.getStreamStatus();
    final audioOffset = _player.backend.getAudioDataOffset();
    if (status != null) {
      final bool audioStartCached =
          status.rangeStart <= audioOffset && status.rangeEnd > audioOffset;
      if (!audioStartCached) {
        await seek(Duration.zero);
        return;
      }
      if (_totalContentLength > 0 && status.rangeEnd >= _totalContentLength) {
        _isStreamEnded = true;
        _state = UnifiedLoaderState.completed;
        _player.backend.streamEnd();
      } else {
        _isStreamEnded = false;
        _state = UnifiedLoaderState.streaming;
        _currentStreamOffset = status.rangeEnd;
        onEngineTelemetryTick();
      }
    } else {
      _state = UnifiedLoaderState.streaming;
    }
  }

  /// Seeks to [position], utilizing the C tripartite `RING` cache for instant
  /// 0-ms cache hits, or opening a random-access stream at `targetByte` on a cache miss.
  Future<void> seek(Duration position) async {
    if (_isDisposed) return;

    if (_isLive && _totalContentLength <= 0) {
      if (_isStopped) {
        _isStopped = false;
        _isStreamEnded = false;
        _isPausedByBackpressure = false;
        final int thisSeekGen = ++_seekGeneration;
        await _cancelActiveStream();
        await _reopenFromOffset(0, thisSeekGen);
      } else {
        await _player.backend.seek(position);
      }
      return;
    }

    final int durationMs = _player.state.duration.inMilliseconds;
    if (durationMs <= 0) {
      await _player.backend.seek(position);
      return;
    }

    final int clampedMs = position.inMilliseconds.clamp(0, durationMs);

    int targetByte = _player.backend.streamGetSeekByte(clampedMs);
    final int audioOffset = _player.backend.getAudioDataOffset();
    if (clampedMs <= 0 && audioOffset > 0) {
      targetByte = audioOffset;
    } else if (targetByte < 0) {
      final int audioStart = audioOffset > 0 ? audioOffset : 0;
      final int audioBytes = _totalContentLength > audioStart
          ? (_totalContentLength - audioStart)
          : _totalContentLength;
      targetByte =
          audioStart + ((clampedMs * audioBytes) ~/ durationMs);
      targetByte = (targetByte ~/ 4) * 4;
    }
    if (_totalContentLength > 4 && targetByte >= _totalContentLength) {
      targetByte = _totalContentLength - 4;
    }
    if (targetByte < 0) targetByte = 0;

    _isStopped = false;

    final prevState = _state;
    _state = UnifiedLoaderState.seeking;
    _isStreamEnded = false;

    // 1. Attempt atomic in-RAM seek in C first!
    // If it is a cache HIT (1), we do NOT cancel any active sequential stream at rangeEnd.
    final int cacheRes = _player.backend.streamSeek(
      clampedMs,
      targetByte,
    );

    if (cacheRes == 1) {
      _isStreamEnded = false;
      _refreshTelemetryFromBackend();
      if (prevState == UnifiedLoaderState.stopped ||
          prevState == UnifiedLoaderState.completed ||
          prevState == UnifiedLoaderState.pausedByBackpressure) {
        _state = UnifiedLoaderState.streaming;
        _isPausedByBackpressure = false;
        _pausedAtHeadroomBytes = 0;
        if (_responseSub != null && _responseSub!.isPaused && !_isFeedingChunk) {
          _resumeSubscription();
        }
      } else {
        _state = prevState;
      }
      onEngineTelemetryTick();
      return;
    }

    // 2. Cache MISS (0): cancel any prior stream and open provider at targetByte.
    _isReopening = true;
    _isPausedByBackpressure = false;
    _isStreamEnded = false;
    final int thisSeekGen = ++_seekGeneration;
    try {
      await _cancelActiveStream();
      if (_isDisposed || _seekGeneration != thisSeekGen) return;

      _player.notifyBuffering(true);
      final res = await provider.open(offset: targetByte);
      if (_isDisposed || _seekGeneration != thisSeekGen) {
        if (_isDisposed) {
          await provider.close();
        } else {
          await provider.abortActiveStream();
        }
        return;
      }
      _currentStreamOffset = targetByte;
      _attachStream(res.stream, thisSeekGen);
    } catch (e) {
      if (_isDisposed || _seekGeneration != thisSeekGen) return;
      _onStreamError(e);
    } finally {
      if (_seekGeneration == thisSeekGen) {
        _isReopening = false;
      }
    }
  }

  /// Stops active downloading and resets the read cursor to 0 while preserving
  /// `HEAD`, `RING`, and `TAIL` in C for instant replay on `play()`.
  Future<void> stop() async {
    _isStopped = true;
    _state = UnifiedLoaderState.stopped;
    _seekGeneration++;
    await _cancelActiveStream();
    _readCursorByte = 0;
    _isPausedByBackpressure = false;
  }

  Future<void> _cancelActiveStream({bool closeProvider = false}) async {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final sub = _responseSub;
    _responseSub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (closeProvider) {
      await provider.close();
    } else {
      await provider.abortActiveStream();
    }
  }

  /// Disposes the loader and closes the underlying [provider].
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _state = UnifiedLoaderState.disposed;
    _seekGeneration++;
    if (_probeCompleter != null && !_probeCompleter!.isCompleted) {
      _probeCompleter!.completeError(
        const MiniaudioPlayerException('Loader disposed before probe completion'),
      );
    }
    await _cancelActiveStream(closeProvider: true);
  }

  static int _detectEncodingFormat(List<int> bytes, String? contentType) {
    if (bytes.length >= 8) {
      if (bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        return 0; // custom backend (miniaudio_aac / minimp4)
      }
    }
    if (bytes.length >= 4) {
      if (bytes[0] == 0x52 &&
          bytes[1] == 0x49 &&
          bytes[2] == 0x46 &&
          bytes[3] == 0x46) {
        return 1; // ma_encoding_format_wav
      }
      if (bytes[0] == 0x66 &&
          bytes[1] == 0x4C &&
          bytes[2] == 0x61 &&
          bytes[3] == 0x43) {
        return 2; // ma_encoding_format_flac
      }
      if ((bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) ||
          (bytes[0] == 0xFF &&
              (bytes[1] & 0xE0) == 0xE0 &&
              (bytes[1] & 0x06) != 0x00)) {
        return 3; // ma_encoding_format_mp3
      }
      if (bytes[0] == 0x4F &&
          bytes[1] == 0x67 &&
          bytes[2] == 0x67 &&
          bytes[3] == 0x53) {
        final probeStr =
            String.fromCharCodes(bytes.sublist(0, min(256, bytes.length)));
        if (probeStr.contains('OpusHead') ||
            (contentType != null &&
                contentType.toLowerCase().contains('opus'))) {
          return 0; // custom libopus decoder
        }
        return 4; // ma_encoding_format_vorbis
      }
    }

    final mime = (contentType ?? '').toLowerCase();
    if (mime.contains('audio/mp4') ||
        mime.contains('audio/m4a') ||
        mime.contains('audio/x-m4a') ||
        mime.contains('audio/aac')) {
      return 0;
    } else if (mime.contains('audio/mpeg') || mime.contains('audio/mp3')) {
      return 3;
    } else if (mime.contains('audio/wav') || mime.contains('audio/x-wav')) {
      return 1;
    } else if (mime.contains('audio/flac')) {
      return 2;
    } else if (mime.contains('audio/opus')) {
      return 0;
    } else if (mime.contains('audio/ogg') || mime.contains('audio/vorbis')) {
      return 4;
    }
    return 0;
  }
}
