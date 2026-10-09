// ignore_for_file: prefer_initializing_formals

import 'audio_device.dart';
import 'dsp_config.dart';
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
  final double Function() _getPreamp;
  final ReplayGainConfig Function() _getReplayGain;
  final double Function() _getBalance;
  final bool Function() _getMono;
  final CrossfeedMode Function() _getCrossfeed;
  final bool Function() _getSpatializerEnabled;
  final double Function() _getSpatializerWidth;
  final bool Function() _getLimiterEnabled;

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
    required double Function() getPreamp,
    required ReplayGainConfig Function() getReplayGain,
    required double Function() getBalance,
    required bool Function() getMono,
    required CrossfeedMode Function() getCrossfeed,
    required bool Function() getSpatializerEnabled,
    required double Function() getSpatializerWidth,
    required bool Function() getLimiterEnabled,
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
        _getVisualizerEnabled = getVisualizerEnabled,
        _getPreamp = getPreamp,
        _getReplayGain = getReplayGain,
        _getBalance = getBalance,
        _getMono = getMono,
        _getCrossfeed = getCrossfeed,
        _getSpatializerEnabled = getSpatializerEnabled,
        _getSpatializerWidth = getSpatializerWidth,
        _getLimiterEnabled = getLimiterEnabled;

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

  /// Current manual preamp gain in decibels applied prior to equalizer (default: 0.0 dB).
  double get preamp => _getPreamp();

  /// Alias for [preamp].
  double get preampDb => _getPreamp();

  /// Current ReplayGain / EBU R128 track normalization configuration.
  ReplayGainConfig get replayGain => _getReplayGain();

  /// Current stereo balance / pan (-1.0 for left, 0.0 for center, +1.0 for right).
  double get balance => _getBalance();

  /// Whether mono downmix is currently active.
  bool get mono => _getMono();

  /// Current headphone binaural crossfeed (Bauer bs2b) mode.
  CrossfeedMode get crossfeed => _getCrossfeed();

  /// Whether stereo widener / spatializer is currently active.
  bool get spatializerEnabled => _getSpatializerEnabled();

  /// Current stereo widener width factor (1.0 to 2.0).
  double get spatializerWidth => _getSpatializerWidth();

  /// Whether the True-Peak soft-knee output limiter protector is active.
  bool get limiterEnabled => _getLimiterEnabled();
}
