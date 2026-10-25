import 'dart:async';
import 'dart:typed_data';

import '../api/audio_analysis_result.dart';
import '../api/audio_device.dart';
import '../api/buffered_range.dart';
import '../api/dsp_config.dart';
import '../api/player_state.dart';
import '../api/silence_skip_config.dart';
import '../api/track_metadata.dart';
import '../api/visualizer_data.dart';
import '../equalizer.dart';
import '../reverb.dart';

/// Snapshot of the C high-level tripartite buffer (`map_buffer_t`) cursors and state.
class BackendStreamStatus {
  final int bufferCapacity;
  final int bufferFill;
  final double fillPercentage;
  final bool isBuffering;
  final bool isEof;
  final int readCursorByte;
  final int rangeStart;
  final int rangeEnd;

  const BackendStreamStatus({
    required this.bufferCapacity,
    required this.bufferFill,
    required this.fillPercentage,
    required this.isBuffering,
    required this.isEof,
    required this.readCursorByte,
    required this.rangeStart,
    required this.rangeEnd,
  });

  int get aheadHeadroomBytes => rangeEnd - readCursorByte;
}

/// Callback listener receiving reactive state and telemetry updates from [PlayerBackend].
abstract class PlayerBackendListener {
  void onState(PlaybackState newState);
  void onPosition(Duration pos);
  void onDuration(Duration dur);
  void onPlaying(bool isPlaying);
  void onBuffering(bool isBuffering);
  void onCompleted(bool isCompleted);
  void onVolume(double volume);
  void onRate(double rate);
  void onPitch(double pitch);
  void onBitrate(int bitrate);
  void onBufferSize(int bufferSize);
  void onSilenceSaved(Duration duration);
  void onSilenceConfig(SilenceSkipConfig config);
  void onBufferedRange(BufferedRange br);
  void onVisualizer(VisualizerData data);
  void onVisualizerEnabled(bool enabled);
  void onDevice(AudioDevice device);
  void onTrackMetadata(AudioTrackMetadata? metadata);
  void onEqualizer(Equalizer equalizer);
  void onPreamp(double preampDb);
  void onReplayGain(ReplayGainConfig config);
  void onBalance(double balance);
  void onMono(bool enabled);
  void onCrossfeed(CrossfeedMode mode);
  void onSpatializer({required bool enabled, required double width});
  void onReverb(Reverb reverb);
  void onLimiter(bool enabled);
  void onError(String message, int errorCode);
}

/// Abstract platform interface bridging the Dart API with the underlying
/// audio engine (Native FFI vs Web WASM Worker).
abstract class PlayerBackend {
  dynamic get handle;
  int get sampleRate;
  int get channels;
  int get pinnedHeadSize;

  Uint8List? getMetaBytes();

  void setListener(PlayerBackendListener listener);

  void init({
    required int sampleRate,
    required int channels,
    required int periodSize,
    String? playbackDeviceId,
  });

  // --- Unified Stream Lifecycle (UnifiedAudioLoader -> map_buffer_t -> map_source) ---
  Future<void> beginOpen();

  Future<int> openStreamEx({
    required Uint8List initialBytes,
    Uint8List? tailBytes,
    required int totalSize,
    required bool isLive,
    required int bufferCapacityBytes,
    int encodingFormat = 0,
  });

  int streamFeed(Uint8List chunk);
  int streamFlush(int newStreamOffset);
  int streamSeek(int positionMs, int newStreamOffset);
  int streamGetSeekByte(int positionMs);
  int getAudioDataOffset();
  int streamEnd();
  void notifyOpenError(int errorCode);
  BackendStreamStatus? getStreamStatus();

  // --- Transport Controls ---
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  // --- Audio & DSP Controls ---
  void setVolume(double volume);
  void setRate(double rate);
  void setPitch(double pitch);
  void setPan(double pan);
  void setBufferSize(int frames);
  void setEqualizerBand(int bandIndex, double gainDb);
  void setEqualizer(Equalizer params);
  void setReverb({
    required bool enabled,
    required double roomSize,
    required double damping,
    required double width,
    required double wet,
    required double dry,
  });
  void setCrossfeed(CrossfeedMode mode);
  void setLimiterEnabled(bool enabled);
  void setSilenceSkip(SilenceSkipConfig config);
  void setVisualizerEnabled(bool enabled);
  void setPreamp(double preampDb);
  void setReplayGain(ReplayGainConfig config);
  void setBalance(double balance);
  void setMono(bool enabled);
  void setSpatializer({required bool enabled, required double width});
  void setIcyMeta(Uint8List data);
  void probeTail(Uint8List data, int tailOffset);
  Future<void> setDevice(String deviceId);
  AudioDevice getCurrentDevice();

  // --- Lifecycle ---
  Future<void> dispose();
}

/// Platform-level audio device enumeration, analysis, and logging service.
abstract class PlatformService {
  Future<List<AudioDevice>> getAudioDevices();
  Stream<List<AudioDevice>> getAudioDevicesStream();
  List<AudioDevice> getAudioDevicesSync();

  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  void setLogLevel(int level);
}
