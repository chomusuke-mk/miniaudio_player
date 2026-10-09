// ignore_for_file: prefer_initializing_formals

import 'audio_device.dart';
import 'silence_skip_config.dart';
import 'visualizer_data.dart';
import '../equalizer.dart';

/// Synchronous snapshot of the current player and DSP states.
class PlayerState {
  final Duration Function() _getPosition;
  final Duration Function() _getDuration;
  final bool Function() _getPlaying;
  final bool Function() _getBuffering;
  final bool Function() _getCompleted;
  final double Function() _getVolume;
  final double Function() _getRate;
  final double Function() _getPitch;
  final int Function() _getBufferSize;
  final int Function() _getAudioBitrate;
  final Equalizer Function() _getEqualizer;
  final AudioDevice Function() _getAudioDevice;
  final bool Function() _getSkipSilence;
  final SilenceSkipMode Function() _getSilenceSkipMode;
  final SilenceSkipConfig Function() _getSilenceConfig;
  final Duration Function() _getSilenceSavedDuration;
  final VisualizerData Function() _getVisualizer;
  final bool Function() _getVisualizerEnabled;

  PlayerState({
    required Duration Function() getPosition,
    required Duration Function() getDuration,
    required bool Function() getPlaying,
    required bool Function() getBuffering,
    required bool Function() getCompleted,
    required double Function() getVolume,
    required double Function() getRate,
    required double Function() getPitch,
    required int Function() getBufferSize,
    required int Function() getAudioBitrate,
    required Equalizer Function() getEqualizer,
    required AudioDevice Function() getAudioDevice,
    required bool Function() getSkipSilence,
    required SilenceSkipMode Function() getSilenceSkipMode,
    required SilenceSkipConfig Function() getSilenceConfig,
    required Duration Function() getSilenceSavedDuration,
    required VisualizerData Function() getVisualizer,
    required bool Function() getVisualizerEnabled,
  })  : _getPosition = getPosition,
        _getDuration = getDuration,
        _getPlaying = getPlaying,
        _getBuffering = getBuffering,
        _getCompleted = getCompleted,
        _getVolume = getVolume,
        _getRate = getRate,
        _getPitch = getPitch,
        _getBufferSize = getBufferSize,
        _getAudioBitrate = getAudioBitrate,
        _getEqualizer = getEqualizer,
        _getAudioDevice = getAudioDevice,
        _getSkipSilence = getSkipSilence,
        _getSilenceSkipMode = getSilenceSkipMode,
        _getSilenceConfig = getSilenceConfig,
        _getSilenceSavedDuration = getSilenceSavedDuration,
        _getVisualizer = getVisualizer,
        _getVisualizerEnabled = getVisualizerEnabled;

  /// Current playback position.
  Duration get position => _getPosition();

  /// Total duration of the current audio file.
  Duration get duration => _getDuration();

  /// Whether audio is actively playing.
  bool get playing => _getPlaying();

  /// Whether audio is currently buffering.
  bool get buffering => _getBuffering();

  /// Whether audio reached the end of the track.
  bool get completed => _getCompleted();

  /// Current volume level (default: 1.0).
  double get volume => _getVolume();

  /// Current playback rate multiplier (default: 1.0).
  double get rate => _getRate();

  /// Current pitch multiplier (default: 1.0).
  double get pitch => _getPitch();

  /// Current internal buffer size in frames (0 = native default).
  int get bufferSize => _getBufferSize();

  /// Current audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  int get audioBitrate => _getAudioBitrate();

  /// Alias for [audioBitrate].
  int get bitrate => _getAudioBitrate();

  /// Current 10-band equalizer settings (default: flat).
  Equalizer get equalizer => _getEqualizer();

  /// Currently active audio output device.
  AudioDevice get audioDevice => _getAudioDevice();

  /// Whether silence skipping is currently enabled.
  bool get skipSilence => _getSkipSilence();

  /// Alias for [skipSilence].
  bool get isSkipSilenceEnabled => _getSkipSilence();

  /// Current silence skipping operational mode.
  SilenceSkipMode get silenceSkipMode => _getSilenceSkipMode();

  /// Current silence detection and skipping configuration.
  SilenceSkipConfig get silenceConfig => _getSilenceConfig();

  /// Cumulative duration of silence saved / skipped in the current track.
  Duration get silenceSavedDuration => _getSilenceSavedDuration();

  /// Real-time audio frequency visualizer snapshot (10 bands matching equalizer + volume metrics).
  VisualizerData get visualizer => _getVisualizer();

  /// Whether real-time visualizer DSP analysis is currently active.
  bool get visualizerEnabled => _getVisualizerEnabled();
}
