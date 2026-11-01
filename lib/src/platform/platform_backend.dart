import 'dart:async';
import 'dart:typed_data';

import '../api/audio_analysis_result.dart';
import '../api/audio_device.dart';
import '../api/buffered_range.dart';
import '../api/dsp_config.dart';
import '../api/player_state.dart';
import '../api/silence_skip_config.dart';
import '../api/spatial.dart';
import '../api/track_metadata.dart';
import '../api/visualizer_data.dart';
import '../equalizer.dart';
import '../reverb.dart';
import '../rust/api/types.dart' show RustDartReadRequest;

/// Listener interface receiving deterministic state and telemetry callbacks
/// from a [PlayerBackend].
abstract class PlayerBackendListener {
  void onState(PlaybackState state);
  void onPosition(Duration position);
  void onDuration(Duration duration);
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
  void onBufferedRange(BufferedRange range);
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

/// Abstract platform backend contract for single-player audio execution.
abstract class PlayerBackend {
  dynamic get handle;
  int get sampleRate;
  int get channels;
  int get pinnedHeadSize;

  Uint8List? getMetaBytes();

  void setListener(PlayerBackendListener listener);

  void init({
    int sampleRate = 48000,
    int channels = 2,
    int periodSize = 2048,
    String? playbackDeviceId,
  });

  Future<void> beginOpen();
  Future<void> openSource(String source, {Map<String, String>? headers});
  Future<void> openMemory(Uint8List bytes);

  Future<void> openCustomStream({
    required int streamId,
    int? totalSize,
    required bool isSeekable,
    required Uint8List initialBytes,
  });

  void supplyCustomBytes({
    required int streamId,
    required int requestId,
    required Uint8List data,
    required bool isEof,
  });

  void notifyCustomError({
    required int streamId,
    required int requestId,
    required String errorMessage,
  });

  Stream<RustDartReadRequest> get onDartReadRequest;

  void notifyOpenError(int errorCode);

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  void setVolume(double volume);
  void setRate(double rate);
  void setPitch(double pitch);
  void setBufferSize(int frames);

  void setEqualizer(Equalizer equalizer);
  void setEqualizerBand(int band, double gainDb);
  void setSilenceSkip(SilenceSkipConfig config);
  void setVisualizerEnabled(bool enabled);
  void setReplayGain(ReplayGainConfig config);
  void setPreamp(double preampDb);
  void setBalance(double balance);
  void setMono(bool enabled);
  void setCrossfeed(CrossfeedMode mode);
  void setSpatializer({required bool enabled, required double width});
  void setReverb({
    required bool enabled,
    required double roomSize,
    required double damping,
    required double width,
    required double wet,
    required double dry,
  });
  void setLimiterEnabled(bool enabled);

  void setSpatialEnabled(bool enabled);
  void setSpatialListener(SpatialListener listener);
  void setSpatialEmitter(SpatialEmitter emitter);
  void setSpatialDopplerFactor(double factor);
  void setSpatialSpeedOfSound(double speed);

  void setIcyMeta(Uint8List data);
  void probeTail(Uint8List data, int tailOffset);

  Future<void> setDevice(String deviceId);
  AudioDevice getCurrentDevice();
  void setPauseOnDeviceChange(bool enabled);
  bool getPauseOnDeviceChange();

  Future<void> dispose();
}

/// Platform-level audio device enumeration, offline acoustic analysis, and logging service.
abstract class PlatformService {
  Future<List<AudioDevice>> getAudioDevices();
  Stream<List<AudioDevice>> getAudioDevicesStream();
  List<AudioDevice> getAudioDevicesSync();
  Future<List<AudioDevice>> getCaptureDevices();
  List<AudioDevice> getCaptureDevicesSync();

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
