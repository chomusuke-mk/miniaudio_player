part of 'miniaudio_player.dart';

/// Maximum payload bytes representable inside standard 32-bit RIFF WAV (`u32::MAX - 36`).
const int _maxRiffDataBytes = 0xFFFFFFFF - 36;

/// Coordinates asynchronous FIFO WAV encoding & finalization from a Push [watchAudioBus]
/// stream into a caller-supplied [RecordingByteBuffer] or Web OPFS worker buffer.
final class _DartBufferRecordingSession<T> {
  final MiniaudioPlayer<T> _player;
  final RecordingByteBuffer _buffer;
  final String displayPath;
  final AudioOutputSource source;
  final WavFormat wavFormat;
  final Future<Uri?> Function()? _finalizeUri;

  int _sampleRate;
  int _channels;
  int _dataBytes = 0;
  int _sampleCount = 0;
  int _droppedFrames = 0;
  bool _stopped = false;
  bool _errorNotified = false;
  MiniaudioPlayerException? _asyncError;

  StreamSubscription<AudioPcmChunk>? _tapSub;
  Future<void> _writeChain = Future<void>.value();

  _DartBufferRecordingSession({
    required MiniaudioPlayer<T> player,
    required RecordingByteBuffer buffer,
    required this.displayPath,
    required this.source,
    required this.wavFormat,
    required int initialSampleRate,
    required int initialChannels,
    Future<Uri?> Function()? finalizeUri,
  })  : _player = player,
        _buffer = buffer,
        _sampleRate = initialSampleRate > 0 ? initialSampleRate : 44100,
        _channels = initialChannels > 0 ? initialChannels : 2,
        _finalizeUri = finalizeUri;

  AudioTapFormat get _tapFormat => wavFormat == WavFormat.float32
      ? AudioTapFormat.float32
      : AudioTapFormat.pcm16;

  static Uint8List _buildWavHeader({
    required int sampleRate,
    required int channels,
    required WavFormat format,
    required int dataBytes,
  }) {
    final bitsPerSample = format == WavFormat.float32 ? 32 : 16;
    final audioFormat = format == WavFormat.float32 ? 3 : 1;
    final ch = channels.clamp(1, 32);
    final sr = sampleRate.clamp(8000, 384000);
    final blockAlign = ch * (bitsPerSample ~/ 8);
    final byteRate = sr * blockAlign;
    final clampedData = dataBytes.clamp(0, _maxRiffDataBytes);
    final riffSize = clampedData + 36;

    final hdr = Uint8List(44);
    final bd = ByteData.sublistView(hdr);

    hdr[0] = 0x52; // R
    hdr[1] = 0x49; // I
    hdr[2] = 0x46; // F
    hdr[3] = 0x46; // F
    bd.setUint32(4, riffSize, Endian.little);
    hdr[8] = 0x57; // W
    hdr[9] = 0x41; // A
    hdr[10] = 0x56; // V
    hdr[11] = 0x45; // E

    hdr[12] = 0x66; // f
    hdr[13] = 0x6D; // m
    hdr[14] = 0x74; // t
    hdr[15] = 0x20; // ' '
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, audioFormat, Endian.little);
    bd.setUint16(22, ch, Endian.little);
    bd.setUint32(24, sr, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, blockAlign, Endian.little);
    bd.setUint16(34, bitsPerSample, Endian.little);

    hdr[36] = 0x64; // d
    hdr[37] = 0x61; // a
    hdr[38] = 0x74; // t
    hdr[39] = 0x61; // a
    bd.setUint32(40, clampedData, Endian.little);

    return hdr;
  }

  /// Validates the target buffer synchronously/asynchronously via a real header write +
  /// seekable `writeAt(0)` probe before attaching the audio tap.
  Future<void> start() async {
    final initialHeader = _buildWavHeader(
      sampleRate: _sampleRate,
      channels: _channels,
      format: wavFormat,
      dataBytes: 0,
    );

    try {
      await _buffer.write(initialHeader);
      await _buffer.writeAt(0, Uint8List.sublistView(initialHeader, 0, 4));
      await _buffer.flush();
    } catch (e) {
      try {
        await _buffer.close();
      } catch (_) {}
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
      _player.state._isRecording = false;
      _player.state._recordingSource = null;
      _player.stream._isRecordingController.add(false);
      _player.stream._recordingSourceController.add(null);
      try {
        await _buffer.close();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _writeChunk(AudioPcmChunk chunk) async {
    if (_stopped || _asyncError != null) return;

    _sampleRate = chunk.sampleRate > 0 ? chunk.sampleRate : _sampleRate;
    _channels = chunk.channels > 0 ? chunk.channels : _channels;
    _droppedFrames = chunk.droppedFrames;

    final raw = chunk.bytes;
    if (raw.isEmpty) return;

    final frameBytes = _channels * _tapFormat.bytesPerSample;
    final remaining = _maxRiffDataBytes - _dataBytes;
    if (remaining < frameBytes) {
      _recordFailure(
        const MiniaudioPlayerException(
          'WAV RIFF 4 GiB maximum file size limit reached.',
          errorCode: MapResult.errorGeneric,
        ),
      );
      return;
    }

    Uint8List toWrite = raw;
    var limitHit = false;
    if (raw.length > remaining) {
      final alignedMax = (remaining ~/ frameBytes) * frameBytes;
      toWrite = Uint8List.sublistView(raw, 0, alignedMax);
      limitHit = true;
    }

    if (toWrite.isNotEmpty) {
      try {
        await _buffer.write(toWrite);
        _dataBytes += toWrite.length;
        _sampleCount += toWrite.length ~/ _tapFormat.bytesPerSample;
        final dur = _currentDuration();
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
        const MiniaudioPlayerException(
          'WAV RIFF 4 GiB maximum file size limit reached.',
          errorCode: MapResult.errorGeneric,
        ),
      );
    }
  }

  void _recordFailure(MiniaudioPlayerException err) {
    _asyncError ??= err;
    if (!_errorNotified) {
      _errorNotified = true;
      _player.state._isRecording = false;
      _player.state._recordingSource = null;
      _player.stream._isRecordingController.add(false);
      _player.stream._recordingSourceController.add(null);
      _player.stream._errorsController.add(err);
    }
  }

  Duration _currentDuration() {
    final samplesPerSec = _sampleRate * _channels;
    if (samplesPerSec <= 0) return Duration.zero;
    return Duration(milliseconds: (_sampleCount * 1000) ~/ samplesPerSec);
  }

  /// Stops capture, drains queued async writes FIFO, patches the RIFF WAV header,
  /// flushes/closes the buffer, and returns the finalized [RecordingResult].
  Future<RecordingResult> stop({bool suppressThrowOnDispose = false}) async {
    _stopped = true;
    final sub = _tapSub;
    _tapSub = null;
    if (sub != null) {
      try {
        await sub.cancel();
      } catch (_) {}
    }

    await _writeChain;

    MiniaudioPlayerException? finalizeErr;
    Uri? resultUri;

    try {
      final finalHeader = _buildWavHeader(
        sampleRate: _sampleRate,
        channels: _channels,
        format: wavFormat,
        dataBytes: _dataBytes,
      );
      await _buffer.writeAt(0, finalHeader);
      await _buffer.flush();
    } catch (e) {
      finalizeErr = e is MiniaudioPlayerException
          ? e
          : MiniaudioPlayerException(
              'Failed to finalize WAV header in buffer: $e',
              errorCode: MapResult.errorGeneric,
            );
    } finally {
      try {
        await _buffer.close();
      } catch (e) {
        finalizeErr ??= e is MiniaudioPlayerException
            ? e
            : MiniaudioPlayerException(
                'Failed to close RecordingByteBuffer: $e',
                errorCode: MapResult.errorGeneric,
              );
      }
      final finalizeUri = _finalizeUri;
      if (finalizeUri != null) {
        try {
          resultUri = await finalizeUri();
        } catch (_) {}
      }
    }

    final finalDur = _currentDuration();
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

    return RecordingResult(
      path: displayPath,
      duration: finalDur,
      bytesWritten: _dataBytes,
      sampleCount: _sampleCount,
      droppedFrames: _droppedFrames,
      uri: resultUri,
    );
  }
}
