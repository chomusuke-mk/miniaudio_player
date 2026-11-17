import 'dart:typed_data';

import '../loader/tap_buffer.dart';
import 'player_models.dart';

/// Sample encoding format emitted by an audio bus tap.
enum AudioTapFormat {
  /// 32-bit IEEE 754 little-endian floating point PCM (`4` bytes per channel sample).
  float32(0, 4),

  /// 16-bit signed integer little-endian linear PCM (`2` bytes per channel sample).
  pcm16(1, 2);

  /// Integer wire code shared with the native engine.
  final int value;

  /// Byte size per single sample in this encoding.
  final int bytesPerSample;

  const AudioTapFormat(this.value, this.bytesPerSample);

  /// Resolves [AudioTapFormat] from its wire code (`0`: float32, `1`: pcm16).
  static AudioTapFormat fromValue(int value) {
    return switch (value) {
      0 => AudioTapFormat.float32,
      1 => AudioTapFormat.pcm16,
      _ => throw ArgumentError.value(value, 'value', 'Invalid AudioTapFormat wire code'),
    };
  }
}

/// Immutable PCM audio batch pushed by [MiniaudioPlayer.watchAudioBus].
///
/// Exposed views ([bytes], [samplesF32], [samplesI16]) are unmodifiable so concurrent
/// subscribers sharing the same `(source, format, frameDuration)` stream cannot mutate
/// backing buffers read by sibling listeners.
class AudioPcmChunk {
  /// Bus source that produced this audio batch.
  final AudioOutputSource source;

  /// PCM sample encoding format of this batch.
  final AudioTapFormat format;

  /// Audio sample rate in Hertz (for example `48000`).
  final int sampleRate;

  /// Interleaved channel count (for example `2`).
  final int channels;

  /// Number of PCM frames represented in this chunk.
  final int frameCount;

  /// Cumulative frames dropped since the tap opened due to downstream backpressure.
  final int droppedFrames;

  final Uint8List _rawBytes;
  Uint8List? _bytesView;
  Float32List? _f32View;
  Int16List? _i16View;

  AudioPcmChunk({
    required this.source,
    required this.format,
    required this.sampleRate,
    required this.channels,
    required this.frameCount,
    required this.droppedFrames,
    required Uint8List bytes,
  }) : _rawBytes = bytes;

  /// Unmodifiable interleaved little-endian PCM byte view (`frameCount * channels * format.bytesPerSample` bytes).
  Uint8List get bytes => _bytesView ??= _rawBytes.asUnmodifiableView();

  /// Unmodifiable interleaved `float32` view of [bytes].
  ///
  /// Throws [StateError] when [format] is not [AudioTapFormat.float32].
  Float32List get samplesF32 {
    if (format != AudioTapFormat.float32) {
      throw StateError(
        'AudioPcmChunk format is $format; samplesF32 is only valid for AudioTapFormat.float32.',
      );
    }
    return _f32View ??= _extractF32(_rawBytes).asUnmodifiableView();
  }

  /// Unmodifiable interleaved `int16` view of [bytes].
  ///
  /// Throws [StateError] when [format] is not [AudioTapFormat.pcm16].
  Int16List get samplesI16 {
    if (format != AudioTapFormat.pcm16) {
      throw StateError(
        'AudioPcmChunk format is $format; samplesI16 is only valid for AudioTapFormat.pcm16.',
      );
    }
    return _i16View ??= _extractI16(_rawBytes).asUnmodifiableView();
  }

  static Float32List _extractF32(Uint8List raw) {
    final len = raw.lengthInBytes ~/ 4;
    if (len == 0) return Float32List(0);
    if ((raw.offsetInBytes & 3) == 0 && Endian.host == Endian.little) {
      return raw.buffer.asFloat32List(raw.offsetInBytes, len);
    }
    final aligned = Uint8List.fromList(raw);
    if (Endian.host == Endian.little) {
      return aligned.buffer.asFloat32List(0, len);
    }
    final bd = ByteData.sublistView(aligned);
    final out = Float32List(len);
    for (var i = 0; i < len; i++) {
      out[i] = bd.getFloat32(i * 4, Endian.little);
    }
    return out;
  }

  static Int16List _extractI16(Uint8List raw) {
    final len = raw.lengthInBytes ~/ 2;
    if (len == 0) return Int16List(0);
    if ((raw.offsetInBytes & 1) == 0 && Endian.host == Endian.little) {
      return raw.buffer.asInt16List(raw.offsetInBytes, len);
    }
    final aligned = Uint8List.fromList(raw);
    if (Endian.host == Endian.little) {
      return aligned.buffer.asInt16List(0, len);
    }
    final bd = ByteData.sublistView(aligned);
    final out = Int16List(len);
    for (var i = 0; i < len; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little);
    }
    return out;
  }
}

/// Zero-allocation reusable PCM Pull buffer reading directly from an engine output bus.
///
/// Ideal for real-time audio sends (for example WebRTC frames, live UDP/WebSocket
/// streaming, or custom visualization loops) where calling [poll] inside a periodic
/// loop must avoid per-frame garbage collection allocations.
class AudioTapBuffer {
  /// Bus source being polled.
  final AudioOutputSource source;

  /// Sample format of the polled PCM frames.
  final AudioTapFormat format;

  /// Audio sample rate in Hertz.
  final int sampleRate;

  /// Interleaved channel count.
  final int channels;

  /// Maximum number of frames held by the reusable buffer per [poll] call.
  final int capacityFrames;

  final PlatformTapBuffer _platform;
  final void Function(int tapId)? _onExplicitClose;

  bool _closed = false;
  int _lastFramesRead = 0;

  AudioTapBuffer({
    required int tapId,
    required this.source,
    required this.format,
    required this.sampleRate,
    required this.channels,
    required this.capacityFrames,
    void Function(int tapId)? onExplicitClose,
  })  : _platform = createPlatformTapBuffer(
          tapId: tapId,
          bytesPerFrame: channels * format.bytesPerSample,
          capacityFrames: capacityFrames,
        ),
        _onExplicitClose = onExplicitClose;

  /// Native handle ID assigned by the engine for this Pull tap.
  int get tapId => _platform.tapId;

  /// Whether this Pull handle has been closed or its owning player disposed.
  bool get isClosed => _closed || _platform.isClosed;

  /// Frame count copied during the most recent [poll] invocation.
  int get lastFramesRead => _lastFramesRead;

  /// Cumulative frames dropped due to overflow since opening this tap.
  int get droppedFrames =>
      _closed ? _platform.lastKnownDropped : _platform.droppedFrames;

  /// Reads up to [maxFrames] (clamped to [capacityFrames]) into the reusable backing buffer.
  ///
  /// Returns the number of PCM frames copied. Performs zero heap allocations per poll.
  int poll({int? maxFrames}) {
    if (isClosed) {
      _lastFramesRead = 0;
      return 0;
    }
    final limit = (maxFrames ?? capacityFrames).clamp(0, capacityFrames);
    if (limit == 0) {
      _lastFramesRead = 0;
      return 0;
    }
    final frames = _platform.pollFrames(limit);
    _lastFramesRead = frames;
    return frames;
  }

  /// Reusable byte view over the `[0 .. lastFramesRead * channels * format.bytesPerSample)` slice.
  Uint8List get bytesView => _platform.bytesSublistView(
        _lastFramesRead * channels * format.bytesPerSample,
      );

  /// Reusable float32 view over `[0 .. lastFramesRead * channels)` samples.
  ///
  /// Throws [StateError] when [format] is not [AudioTapFormat.float32].
  Float32List get float32View {
    if (format != AudioTapFormat.float32) {
      throw StateError(
        'float32View is only valid when format == AudioTapFormat.float32.',
      );
    }
    return _platform.float32SublistView(_lastFramesRead * channels);
  }

  /// Reusable int16 view over `[0 .. lastFramesRead * channels)` samples.
  ///
  /// Throws [StateError] when [format] is not [AudioTapFormat.pcm16].
  Int16List get int16View {
    if (format != AudioTapFormat.pcm16) {
      throw StateError(
        'int16View is only valid when format == AudioTapFormat.pcm16.',
      );
    }
    return _platform.int16SublistView(_lastFramesRead * channels);
  }

  /// Closes this Pull tap immediately and clears its RT bus bit when no subscribers remain.
  void close() {
    if (_closed) return;
    _closed = true;
    _lastFramesRead = 0;
    _platform.close();
    _onExplicitClose?.call(_platform.tapId);
  }
}
