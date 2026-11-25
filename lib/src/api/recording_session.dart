part of 'miniaudio_player.dart';

/// Frames per block for streaming lossless WavPack (`.wv`) encoding (`wavicle`).
const int _wavpackBlockFrames = 32768;

/// Sony Wave64 RIFF chunk GUID bytes.
const List<int> _w64RiffGuid = [
  0x72,
  0x69,
  0x66,
  0x66,
  0x2e,
  0x91,
  0xcf,
  0x11,
  0xa5,
  0xd6,
  0x28,
  0xdb,
  0x04,
  0xc1,
  0x00,
  0x00,
];

/// Sony Wave64 WAVE chunk GUID bytes.
const List<int> _w64WaveGuid = [
  0x77,
  0x61,
  0x76,
  0x65,
  0xf3,
  0xac,
  0xd3,
  0x11,
  0x8c,
  0xd1,
  0x00,
  0xc0,
  0x4f,
  0x8e,
  0xdb,
  0x8a,
];

/// Sony Wave64 fmt subchunk GUID bytes.
const List<int> _w64FmtGuid = [
  0x66,
  0x6d,
  0x74,
  0x20,
  0xf3,
  0xac,
  0xd3,
  0x11,
  0x8c,
  0xd1,
  0x00,
  0xc0,
  0x4f,
  0x8e,
  0xdb,
  0x8a,
];

/// Sony Wave64 data subchunk GUID bytes.
const List<int> _w64DataGuid = [
  0x64,
  0x61,
  0x74,
  0x61,
  0xf3,
  0xac,
  0xd3,
  0x11,
  0x8c,
  0xd1,
  0x00,
  0xc0,
  0x4f,
  0x8e,
  0xdb,
  0x8a,
];

/// Writes ASCII characters of [tag] into [dst] starting at byte [offset].
void _writeAscii(Uint8List dst, int offset, String tag) {
  for (var i = 0; i < tag.length; i++) {
    dst[offset + i] = tag.codeUnitAt(i);
  }
}

/// Writes an unsigned 64-bit integer [value] into [bd] at [offset] using [endian].
///
/// Splits the value into 32-bit halves to avoid 64-bit `>> 32` integer shifts
/// in dart2js on Web targets.
void _setUint64(ByteData bd, int offset, int value, Endian endian) {
  final hi = (value ~/ 0x100000000) & 0xFFFFFFFF;
  final lo = value & 0xFFFFFFFF;
  if (endian == Endian.little) {
    bd.setUint32(offset, lo, Endian.little);
    bd.setUint32(offset + 4, hi, Endian.little);
  } else {
    bd.setUint32(offset, hi, Endian.big);
    bd.setUint32(offset + 4, lo, Endian.big);
  }
}

/// Encodes an integer [sampleRate] as an 80-bit IEEE 754 extended float into [bd] at [offset].
void _encodeAiffExtendedF80(ByteData bd, int offset, int sampleRate) {
  if (sampleRate <= 0) {
    bd.setUint16(offset, 0, Endian.big);
    bd.setUint32(offset + 2, 0, Endian.big);
    bd.setUint32(offset + 6, 0, Endian.big);
    return;
  }
  var shift = 0;
  var v = sampleRate & 0xFFFFFFFF;
  while ((v & 0x80000000) == 0 && shift < 32) {
    v = (v << 1) & 0xFFFFFFFF;
    shift++;
  }
  final exp = 16383 + 31 - shift;
  bd.setUint16(offset, exp, Endian.big);
  bd.setUint32(offset + 2, v, Endian.big);
  bd.setUint32(offset + 6, 0, Endian.big);
}

/// Writes the 16-byte WAVE `fmt ` body into [bd] at [offset] for sample rate [sr],
/// channel count [ch], and PCM/IEEE-float format [isFloat].
void _writeWaveFmtBody(ByteData bd, int offset, int sr, int ch, bool isFloat) {
  final bps = isFloat ? 32 : 16;
  final audioFormat = isFloat ? 3 : 1;
  final blockAlign = ch * (bps ~/ 8);
  final byteRate = sr * blockAlign;
  bd.setUint16(offset, audioFormat, Endian.little);
  bd.setUint16(offset + 2, ch, Endian.little);
  bd.setUint32(offset + 4, sr, Endian.little);
  bd.setUint32(offset + 8, byteRate, Endian.little);
  bd.setUint16(offset + 12, blockAlign, Endian.little);
  bd.setUint16(offset + 14, bps, Endian.little);
}

/// Coordinates asynchronous FIFO container encoding and finalization from a Push
/// [MiniaudioPlayer.watchAudioBus] stream into a [RecordingByteBuffer].
final class _DartBufferRecordingSession<T> {
  /// Owning player whose audio bus tap feeds this session.
  final MiniaudioPlayer<T> _player;

  /// Target random-access byte sink receiving encoded audio data and headers.
  final RecordingByteBuffer _buffer;

  /// Display or destination path reported in the resulting [RecordingResult].
  final String displayPath;

  /// Audio bus source tapped for recording.
  final AudioOutputSource source;

  /// Target container and PCM encoding format.
  final AudioFileFormat encoding;

  /// Active sample rate in Hz, updated from incoming tap chunks.
  int _sampleRate;

  /// Active channel count, updated from incoming tap chunks.
  int _channels;

  /// Total raw PCM payload bytes processed before container framing.
  int _pcmDataBytes = 0;

  /// Total encoded bytes written into [_buffer] (excluding container headers).
  int _writtenDataBytes = 0;

  /// Total interleaved PCM sample count written so far.
  int _sampleCount = 0;

  /// Cumulative dropped frames reported by the audio tap.
  int _droppedFrames = 0;

  /// Running frame index for consecutive WavPack blocks.
  int _wvBlockIndexFrames = 0;

  /// Whether the initial 4-byte WavPack startup probe has been overwritten.
  bool _wvHeaderReplaced = false;

  /// Whether [stop] has been invoked to halt further chunk processing.
  bool _stopped = false;

  /// Whether [_recordFailure] has already emitted state and error notifications.
  bool _errorNotified = false;

  /// First asynchronous error captured during streaming capture or encoding.
  MiniaudioPlayerException? _asyncError;

  /// Reusable scratch buffer for big-endian AIFF byte swapping.
  Uint8List _endianScratch = Uint8List(0);

  /// Pending PCM bytes awaiting a full WavPack block.
  final BytesBuilder _wvPending = BytesBuilder(copy: false);

  /// Subscription to the push audio bus tap stream.
  StreamSubscription<AudioPcmChunk>? _tapSub;

  /// Serialized FIFO future chain ensuring ordered writes to [_buffer].
  Future<void> _writeChain = Future<void>.value();

  /// Creates a [_DartBufferRecordingSession] writing [source] from [player]
  /// into [buffer] using [encoding].
  ///
  /// Uses [displayPath] for diagnostics and [RecordingResult.path], while
  /// initializing header parameters with [initialSampleRate] and [initialChannels].
  _DartBufferRecordingSession({
    required MiniaudioPlayer<T> player,
    required RecordingByteBuffer buffer,
    required this.displayPath,
    required this.source,
    required this.encoding,
    required int initialSampleRate,
    required int initialChannels,
  })  : _player = player,
        _buffer = buffer,
        _sampleRate = initialSampleRate > 0 ? initialSampleRate : 44100,
        _channels = initialChannels > 0 ? initialChannels : 2;

  /// Tap PCM sample format corresponding to [encoding].
  AudioTapFormat get _tapFormat =>
      encoding.isFloat32 ? AudioTapFormat.float32 : AudioTapFormat.pcm16;

  /// Builds the container header for [encoding] using [sampleRate], [channels],
  /// payload size [dataBytes], and [totalFrames].
  static Uint8List _buildContainerHeader({
    required AudioFileFormat encoding,
    required int sampleRate,
    required int channels,
    required int dataBytes,
    required int totalFrames,
  }) {
    final ch = channels.clamp(1, 32);
    final sr = sampleRate.clamp(8000, 384000);

    switch (encoding) {
      case AudioFileFormat.wav:
      case AudioFileFormat.wavFloat32:
        final hdr = Uint8List(44);
        final bd = ByteData.sublistView(hdr);
        final clamped = dataBytes.clamp(0, 0xFFFFFFFF - 36);
        _writeAscii(hdr, 0, 'RIFF');
        bd.setUint32(4, dataBytes == 0 ? 0 : clamped + 36, Endian.little);
        _writeAscii(hdr, 8, 'WAVEfmt ');
        bd.setUint32(16, 16, Endian.little);
        _writeWaveFmtBody(bd, 20, sr, ch, encoding.isFloat32);
        _writeAscii(hdr, 36, 'data');
        bd.setUint32(40, clamped, Endian.little);
        return hdr;

      case AudioFileFormat.rf64:
      case AudioFileFormat.rf64Float32:
        final hdr = Uint8List(80);
        final bd = ByteData.sublistView(hdr);
        final riff32 =
            dataBytes == 0 ? 0 : (dataBytes + 72).clamp(0, 0xFFFFFFFF);
        final data32 = dataBytes.clamp(0, 0xFFFFFFFF);
        _writeAscii(hdr, 0, 'RF64');
        bd.setUint32(4, riff32, Endian.little);
        _writeAscii(hdr, 8, 'WAVEds64');
        bd.setUint32(16, 28, Endian.little);
        _setUint64(bd, 20, dataBytes + 72, Endian.little);
        _setUint64(bd, 28, dataBytes, Endian.little);
        _setUint64(bd, 36, totalFrames, Endian.little);
        bd.setUint32(44, 0, Endian.little);
        _writeAscii(hdr, 48, 'fmt ');
        bd.setUint32(52, 16, Endian.little);
        _writeWaveFmtBody(bd, 56, sr, ch, encoding.isFloat32);
        _writeAscii(hdr, 72, 'data');
        bd.setUint32(76, data32, Endian.little);
        return hdr;

      case AudioFileFormat.w64:
      case AudioFileFormat.w64Float32:
        final hdr = Uint8List(104);
        final bd = ByteData.sublistView(hdr);
        hdr.setAll(0, _w64RiffGuid);
        _setUint64(bd, 16, dataBytes + 104, Endian.little);
        hdr.setAll(24, _w64WaveGuid);
        hdr.setAll(40, _w64FmtGuid);
        _setUint64(bd, 56, 40, Endian.little);
        _writeWaveFmtBody(bd, 64, sr, ch, encoding.isFloat32);
        hdr.setAll(80, _w64DataGuid);
        _setUint64(bd, 96, dataBytes + 24, Endian.little);
        return hdr;

      case AudioFileFormat.aiff:
        final hdr = Uint8List(54);
        final bd = ByteData.sublistView(hdr);
        final clamped = dataBytes.clamp(0, 0xFFFFFFFF - 46);
        final padded = clamped + (clamped & 1);
        final frames32 = totalFrames.clamp(0, 0xFFFFFFFF);
        _writeAscii(hdr, 0, 'FORM');
        bd.setUint32(4, dataBytes == 0 ? 0 : padded + 46, Endian.big);
        _writeAscii(hdr, 8, 'AIFFCOMM');
        bd.setUint32(16, 18, Endian.big);
        bd.setUint16(20, ch, Endian.big);
        bd.setUint32(22, frames32, Endian.big);
        bd.setUint16(26, 16, Endian.big);
        _encodeAiffExtendedF80(bd, 28, sr);
        _writeAscii(hdr, 38, 'SSND');
        bd.setUint32(42, clamped + 8, Endian.big);
        bd.setUint32(46, 0, Endian.big);
        bd.setUint32(50, 0, Endian.big);
        return hdr;

      case AudioFileFormat.caf:
      case AudioFileFormat.cafFloat32:
        final hdr = Uint8List(68);
        final bd = ByteData.sublistView(hdr);
        final bps = encoding.bitsPerSample;
        final bytesPerPacket = ch * (bps ~/ 8);
        final flags = encoding.isFloat32 ? 1 : 0;
        _writeAscii(hdr, 0, 'caff');
        bd.setUint16(4, 1, Endian.big);
        bd.setUint16(6, 0, Endian.big);
        _writeAscii(hdr, 8, 'desc');
        _setUint64(bd, 12, 32, Endian.big);
        bd.setFloat64(20, sr.toDouble(), Endian.big);
        _writeAscii(hdr, 28, 'lpcm');
        bd.setUint32(32, flags, Endian.big);
        bd.setUint32(36, bytesPerPacket, Endian.big);
        bd.setUint32(40, 1, Endian.big);
        bd.setUint32(44, ch, Endian.big);
        bd.setUint32(48, bps, Endian.big);
        _writeAscii(hdr, 52, 'data');
        _setUint64(bd, 56, dataBytes + 4, Endian.big);
        bd.setUint32(64, 0, Endian.big);
        return hdr;

      case AudioFileFormat.wavPack:
      case AudioFileFormat.wavPackFloat32:
        // 4-byte startup write/seek probe; overwritten when block 0 is written.
        return Uint8List.fromList(const [0x77, 0x76, 0x70, 0x6B]);

      case AudioFileFormat.mp3:
      case AudioFileFormat.flac:
        throw StateError(
            'Unreachable unsupported recording encoding: $encoding');
    }
  }

  /// Byte-swaps little-endian PCM [raw] samples of width [sampleBytes] to big-endian.
  Uint8List _swapToBigEndian(Uint8List raw, int sampleBytes) {
    if (_endianScratch.length < raw.length) {
      _endianScratch = Uint8List(raw.length);
    }
    if (sampleBytes == 2) {
      for (var i = 0; i + 1 < raw.length; i += 2) {
        _endianScratch[i] = raw[i + 1];
        _endianScratch[i + 1] = raw[i];
      }
    } else {
      for (var i = 0; i + 3 < raw.length; i += 4) {
        _endianScratch[i] = raw[i + 3];
        _endianScratch[i + 1] = raw[i + 2];
        _endianScratch[i + 2] = raw[i + 1];
        _endianScratch[i + 3] = raw[i];
      }
    }
    return Uint8List.sublistView(_endianScratch, 0, raw.length);
  }

  /// Validates channel constraints and tests writable `writeAt(0)` behavior on [_buffer].
  ///
  /// Once initial header validation succeeds, updates player recording state and
  /// attaches the audio bus tap subscription.
  Future<void> start() async {
    if (encoding.isWavPack && _channels != 1 && _channels != 2) {
      MapLogger.error(
        '[RecordingSession] Unsupported WavPack channel count $_channels for "$displayPath".',
      );
      throw MiniaudioPlayerException(
        'WavPack recording supports 1 or 2 channels (got $_channels).',
        errorCode: MapResult.errorUnsupported,
      );
    }

    final initialHeader = _buildContainerHeader(
      encoding: encoding,
      sampleRate: _sampleRate,
      channels: _channels,
      dataBytes: 0,
      totalFrames: 0,
    );

    MapLogger.debug(
      '[RecordingSession] Validating initial ${encoding.name} header on RecordingByteBuffer "$displayPath" (sr=$_sampleRate, ch=$_channels).',
    );
    try {
      await _buffer.write(initialHeader);
      await _buffer.writeAt(0, Uint8List.sublistView(initialHeader, 0, 4));
      await _buffer.flush();
    } catch (e) {
      MapLogger.error(
        '[RecordingSession] RecordingByteBuffer validation failed for "$displayPath": $e',
      );
      try {
        await _buffer.close();
      } catch (closeErr) {
        MapLogger.warn(
          '[RecordingSession] Failed to close RecordingByteBuffer after validation failure: $closeErr',
        );
      }
      if (e is MiniaudioPlayerException) rethrow;
      throw MiniaudioPlayerException(
        'RecordingByteBuffer failed initial write/writeAt validation: $e',
        errorCode: MapResult.errorInvalidArgs,
      );
    }

    _player.state._recordedDuration = Duration.zero;
    _player.state._recordingSource = source;
    _player.state._isRecording = true;
    _player.stream._recordedDurationController.add(Duration.zero);
    _player.stream._recordingSourceController.add(source);
    _player.stream._isRecordingController.add(true);

    MapLogger.info(
      '[RecordingSession] Starting Dart buffer recording (${encoding.name}, source=${source.name}, sr=$_sampleRate, ch=$_channels, path="$displayPath").',
    );
    try {
      _tapSub = _player
          .watchAudioBus(
        source: source,
        format: _tapFormat,
        frameDuration: const Duration(milliseconds: 20),
      )
          .listen(
        (chunk) {
          if (_stopped || _asyncError != null) return;
          _writeChain = _writeChain.then((_) => _writeChunk(chunk));
        },
        onError: (Object err, StackTrace _) {
          _recordFailure(
            err is MiniaudioPlayerException
                ? err
                : MiniaudioPlayerException(
                    'Recording tap stream error: $err',
                    errorCode: MapResult.errorGeneric,
                  ),
          );
        },
      );
    } catch (e) {
      MapLogger.error(
        '[RecordingSession] Failed to attach audio bus tap for "$displayPath": $e',
      );
      _player.state._isRecording = false;
      _player.state._recordingSource = null;
      _player.stream._isRecordingController.add(false);
      _player.stream._recordingSourceController.add(null);
      try {
        await _buffer.close();
      } catch (closeErr) {
        MapLogger.warn(
          '[RecordingSession] Failed to close RecordingByteBuffer after tap attach failure: $closeErr',
        );
      }
      rethrow;
    }
  }

  /// Encodes [pcmBlockBytes] as a single WavPack block and appends it to [_buffer].
  ///
  /// Updates recorded byte and sample counters when [countAsAudioFrames] is `true`.
  Future<void> _writeWavPackBlock(
    Uint8List pcmBlockBytes, {
    bool countAsAudioFrames = true,
  }) async {
    final frameBytes = _channels * _tapFormat.bytesPerSample;
    final frames = frameBytes > 0 ? pcmBlockBytes.length ~/ frameBytes : 0;
    if (frames <= 0) return;

    final encoded = await rust.encodeWavpackBlock(
      sampleRate: _sampleRate,
      channels: _channels,
      isFloat: encoding.isFloat32,
      blockIndex: BigInt.from(_wvBlockIndexFrames),
      pcmBytes: pcmBlockBytes,
    );
    if (encoded.isEmpty) return;

    if (!_wvHeaderReplaced) {
      final headLen = encoded.length >= 4 ? 4 : encoded.length;
      await _buffer.writeAt(0, Uint8List.sublistView(encoded, 0, headLen));
      if (encoded.length > headLen) {
        await _buffer.write(Uint8List.sublistView(encoded, headLen));
      }
      _wvHeaderReplaced = true;
    } else {
      await _buffer.write(encoded);
    }

    _wvBlockIndexFrames += frames;
    if (countAsAudioFrames) {
      _pcmDataBytes += pcmBlockBytes.length;
      _writtenDataBytes += encoded.length;
      _sampleCount += frames * _channels;
    }
  }

  /// Buffers incoming PCM [raw] bytes and emits complete WavPack blocks as they fill.
  Future<void> _appendWavPackChunk(Uint8List raw) async {
    final frameBytes = _channels * _tapFormat.bytesPerSample;
    final blockBytes = _wavpackBlockFrames * frameBytes;
    var offset = 0;

    if (_wvPending.isNotEmpty && _wvPending.length + raw.length >= blockBytes) {
      final need = blockBytes - _wvPending.length;
      _wvPending.add(Uint8List.sublistView(raw, 0, need));
      await _writeWavPackBlock(_wvPending.takeBytes());
      offset = need;
    }

    while (raw.length - offset >= blockBytes) {
      await _writeWavPackBlock(
        Uint8List.sublistView(raw, offset, offset + blockBytes),
      );
      offset += blockBytes;
    }

    if (offset < raw.length) {
      _wvPending.add(Uint8List.sublistView(raw, offset));
    }
  }

  /// Processes a single incoming [chunk] from the audio tap and writes it to [_buffer].
  Future<void> _writeChunk(AudioPcmChunk chunk) async {
    if (_stopped || _asyncError != null) return;

    _sampleRate = chunk.sampleRate > 0 ? chunk.sampleRate : _sampleRate;
    _channels = chunk.channels > 0 ? chunk.channels : _channels;
    _droppedFrames = chunk.droppedFrames;

    final raw = chunk.bytes;
    if (raw.isEmpty) return;

    final frameBytes = _channels * _tapFormat.bytesPerSample;

    if (encoding.isWavPack) {
      try {
        await _appendWavPackChunk(raw);
        final totalPendingSamples =
            _sampleCount + (_wvPending.length ~/ _tapFormat.bytesPerSample);
        final dur = _durationForSamples(totalPendingSamples);
        _player.state._recordedDuration = dur;
        _player.stream._recordedDurationController.add(dur);
      } catch (e) {
        _recordFailure(
          e is MiniaudioPlayerException
              ? e
              : MiniaudioPlayerException(
                  'WavPack recording failure: $e',
                  errorCode: MapResult.errorGeneric,
                ),
        );
      }
      return;
    }

    final maxPayload = encoding.maxPayloadBytes;
    Uint8List toWrite = raw;
    var limitHit = false;
    if (maxPayload != null) {
      final remaining = maxPayload - _pcmDataBytes;
      if (remaining < frameBytes) {
        _recordFailure(
          MiniaudioPlayerException(
            '${encoding.name.toUpperCase()} 4 GiB maximum file size limit reached. '
            'Use AudioFileFormat.rf64, w64, caf, or wavPack for >4 GiB recordings.',
            errorCode: MapResult.errorGeneric,
          ),
        );
        return;
      }
      if (raw.length > remaining) {
        final alignedMax = (remaining ~/ frameBytes) * frameBytes;
        toWrite = Uint8List.sublistView(raw, 0, alignedMax);
        limitHit = true;
      }
    }

    if (toWrite.isNotEmpty) {
      try {
        final serialized = encoding.isBigEndian
            ? _swapToBigEndian(toWrite, _tapFormat.bytesPerSample)
            : toWrite;
        await _buffer.write(serialized);
        _pcmDataBytes += toWrite.length;
        _writtenDataBytes += serialized.length;
        _sampleCount += toWrite.length ~/ _tapFormat.bytesPerSample;
        final dur = _durationForSamples(_sampleCount);
        _player.state._recordedDuration = dur;
        _player.stream._recordedDurationController.add(dur);
      } catch (e) {
        _recordFailure(
          e is MiniaudioPlayerException
              ? e
              : MiniaudioPlayerException(
                  'Recording write failure: $e',
                  errorCode: MapResult.errorGeneric,
                ),
        );
        return;
      }
    }

    if (limitHit) {
      _recordFailure(
        MiniaudioPlayerException(
          '${encoding.name.toUpperCase()} 4 GiB maximum file size limit reached.',
          errorCode: MapResult.errorGeneric,
        ),
      );
    }
  }

  /// Records the first fatal error [err] and notifies player state and error streams.
  void _recordFailure(MiniaudioPlayerException err) {
    _asyncError ??= err;
    if (!_errorNotified) {
      _errorNotified = true;
      MapLogger.error(
        '[RecordingSession] Recording failed for "$displayPath": $err',
      );
      _player.state._isRecording = false;
      _player.state._recordingSource = null;
      _player.stream._isRecordingController.add(false);
      _player.stream._recordingSourceController.add(null);
      _player.stream._errorsController.add(err);
    }
  }

  /// Converts an interleaved [totalSamples] count into a [Duration].
  Duration _durationForSamples(int totalSamples) {
    final samplesPerSec = _sampleRate * _channels;
    if (samplesPerSec <= 0) return Duration.zero;
    return Duration(milliseconds: (totalSamples * 1000) ~/ samplesPerSec);
  }

  /// Flushes trailing audio blocks, patches final container headers, and flushes [_buffer].
  Future<void> _finalizeBuffer() async {
    if (encoding.isWavPack) {
      final frameBytes = _channels * _tapFormat.bytesPerSample;
      final remaining = _wvPending.takeBytes();
      final aligned =
          frameBytes > 0 ? (remaining.length ~/ frameBytes) * frameBytes : 0;
      if (aligned > 0) {
        await _writeWavPackBlock(Uint8List.sublistView(remaining, 0, aligned));
      }
      if (_writtenDataBytes == 0) {
        await _writeWavPackBlock(
          Uint8List(frameBytes),
          countAsAudioFrames: false,
        );
      }
      final totalFrames = _channels > 0 ? _sampleCount ~/ _channels : 0;
      final totalPatch = Uint8List(5);
      totalPatch[0] = (totalFrames ~/ 0x100000000) & 0xFF;
      ByteData.sublistView(totalPatch)
          .setUint32(1, totalFrames & 0xFFFFFFFF, Endian.little);
      await _buffer.writeAt(11, totalPatch);
      await _buffer.flush();
      return;
    }

    if (encoding == AudioFileFormat.aiff && (_pcmDataBytes & 1) == 1) {
      await _buffer.write(Uint8List(1));
    }
    final totalFrames = _channels > 0 ? _sampleCount ~/ _channels : 0;
    final finalHeader = _buildContainerHeader(
      encoding: encoding,
      sampleRate: _sampleRate,
      channels: _channels,
      dataBytes: _pcmDataBytes,
      totalFrames: totalFrames,
    );
    await _buffer.writeAt(0, finalHeader);
    await _buffer.flush();
  }

  /// Stops capture, drains queued writes, finalizes headers, and returns [RecordingResult].
  ///
  /// When [suppressThrowOnDispose] is `true`, deferred capture or finalization errors
  /// are suppressed so player disposal can finish cleanly.
  Future<RecordingResult> stop({bool suppressThrowOnDispose = false}) async {
    MapLogger.info(
      '[RecordingSession] Stopping Dart buffer recording "$displayPath" (suppressThrowOnDispose=$suppressThrowOnDispose).',
    );
    _stopped = true;
    final sub = _tapSub;
    _tapSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (e) {
        MapLogger.warn(
          '[RecordingSession] Failed to cancel tap subscription while stopping "$displayPath": $e',
        );
      }
    }

    await _writeChain;

    MiniaudioPlayerException? finalizeErr;

    try {
      await _finalizeBuffer();
    } catch (e) {
      MapLogger.error(
        '[RecordingSession] Failed to finalize ${encoding.name.toUpperCase()} buffer "$displayPath": $e',
      );
      finalizeErr = e is MiniaudioPlayerException
          ? e
          : MiniaudioPlayerException(
              'Failed to finalize ${encoding.name.toUpperCase()} header in buffer: $e',
              errorCode: MapResult.errorGeneric,
            );
    } finally {
      try {
        await _buffer.close();
      } catch (e) {
        MapLogger.error(
          '[RecordingSession] Failed to close RecordingByteBuffer "$displayPath": $e',
        );
        finalizeErr ??= e is MiniaudioPlayerException
            ? e
            : MiniaudioPlayerException(
                'Failed to close RecordingByteBuffer: $e',
                errorCode: MapResult.errorGeneric,
              );
      }
    }

    final finalDur = _durationForSamples(_sampleCount);
    _player.state._recordedDuration = finalDur;
    _player.state._isRecording = false;
    _player.state._recordingSource = null;
    _player.stream._recordedDurationController.add(finalDur);
    _player.stream._isRecordingController.add(false);
    _player.stream._recordingSourceController.add(null);

    final effectiveError = _asyncError ?? finalizeErr;
    if (effectiveError != null && !suppressThrowOnDispose) {
      throw effectiveError;
    }

    MapLogger.info(
      '[RecordingSession] Completed recording "$displayPath" (duration=$finalDur, bytes=$_writtenDataBytes, samples=$_sampleCount, droppedFrames=$_droppedFrames).',
    );

    final buffer = _buffer;
    return RecordingResult(
      path: displayPath,
      duration: finalDur,
      bytesWritten: _writtenDataBytes,
      sampleCount: _sampleCount,
      droppedFrames: _droppedFrames,
      format: encoding,
      isOpfs: false,
      memoryBuffer: buffer is MemoryRecordingBuffer ? buffer : null,
    );
  }
}
