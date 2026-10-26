// ignore_for_file: prefer_initializing_formals

import 'dart:typed_data';

import 'audio_device.dart';
import 'buffered_range.dart';
import 'dsp_config.dart';
import 'silence_skip_config.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';
import '../equalizer.dart';
import '../reverb.dart';

/// Represents the high-level playback and lifecycle states of [MiniaudioPlayer].
enum PlaybackState {
  /// The player is stopped, rewound to start, or has no active media.
  stopped,

  /// The player is actively preparing, resolving, probing, or loading an audio source.
  opening,

  /// Audio frames are actively rendering through the output audio device.
  playing,

  /// Playback is paused at the current position.
  paused,

  /// Playback reached the end of the track.
  completed,

  /// Playback is stalled waiting for network data or buffer replenishment.
  buffering,

  /// An unrecoverable decoding, I/O, or native engine error occurred.
  error;

  /// Convenience boolean predicates
  bool get isStopped => this == PlaybackState.stopped;
  bool get isOpening => this == PlaybackState.opening;
  bool get isPlaying => this == PlaybackState.playing;
  bool get isPaused => this == PlaybackState.paused;
  bool get isCompleted => this == PlaybackState.completed;
  bool get isBuffering => this == PlaybackState.buffering;
  bool get isError => this == PlaybackState.error;
}

/// Synchronous snapshot of the current player and DSP states.
class PlayerState {
  final Duration Function() _getPosition;
  final Duration Function() _getDuration;
  final bool Function() _getPlaying;
  final bool Function() _getBuffering;
  final bool Function() _getCompleted;
  final bool Function() _getOpening;
  final PlaybackState Function() _getPlaybackState;
  final Duration Function() _getBufferedPosition;
  final double Function() _getBufferedPercentage;
  final BufferedRange Function() _getBufferedRange;
  final AudioTrackMetadata? Function() _getTrackMetadata;
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
  final Reverb Function() _getReverb;
  final bool Function() _getLimiterEnabled;
  final Uint8List? Function()? _getMetaBytes;

  PlayerState({
    required Duration Function() getPosition,
    required Duration Function() getDuration,
    required bool Function() getPlaying,
    required bool Function() getBuffering,
    required bool Function() getCompleted,
    required bool Function() getOpening,
    required PlaybackState Function() getPlaybackState,
    required Duration Function() getBufferedPosition,
    required double Function() getBufferedPercentage,
    required BufferedRange Function() getBufferedRange,
    required AudioTrackMetadata? Function() getTrackMetadata,
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
    required Reverb Function() getReverb,
    required bool Function() getLimiterEnabled,
    Uint8List? Function()? getMetaBytes,
  })  : _getPosition = getPosition,
        _getDuration = getDuration,
        _getPlaying = getPlaying,
        _getBuffering = getBuffering,
        _getCompleted = getCompleted,
        _getOpening = getOpening,
        _getPlaybackState = getPlaybackState,
        _getBufferedPosition = getBufferedPosition,
        _getBufferedPercentage = getBufferedPercentage,
        _getBufferedRange = getBufferedRange,
        _getTrackMetadata = getTrackMetadata,
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
        _getReverb = getReverb,
        _getLimiterEnabled = getLimiterEnabled,
        _getMetaBytes = getMetaBytes;

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

  /// Whether the player is currently opening or preparing an audio source.
  bool get opening => _getOpening();

  /// Comprehensive playback state enum representing the current lifecycle phase.
  PlaybackState get playbackState => _getPlaybackState();

  /// Furthest continuous timestamp preloaded in RAM buffer.
  Duration get bufferedPosition => _getBufferedPosition();

  /// Fraction (0.0 to 1.0) of the total track loaded into the buffer (for preloaded bar).
  double get bufferedPercentage => _getBufferedPercentage();

  /// Comprehensive sliding-window circular buffer telemetry metrics.
  BufferedRange get bufferedRange => _getBufferedRange();

  /// Current audio track metadata, or `null` if no track is opened.
  AudioTrackMetadata? get trackMetadata => _getTrackMetadata();

  /// Current volume level (default: 1.0).
  double get volume => _getVolume();

  /// Current playback rate multiplier (default: 1.0).
  double get rate => _getRate();

  /// Current pitch multiplier (default: 1.0).
  double get pitch => _getPitch();

  /// Current internal buffer size in frames (0 = native default).
  int get bufferSize => _getBufferSize();

  /// Current audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  int get bitrate => _getAudioBitrate();

  /// Current 10-band equalizer settings (default: flat).
  Equalizer get equalizer => _getEqualizer();

  /// Currently active audio output device.
  AudioDevice get audioDevice => _getAudioDevice();

  /// Whether silence skipping is currently enabled.
  bool get skipSilence => _getSkipSilence();

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

  /// Current studio reverberation configuration.
  Reverb get reverb => _getReverb();

  /// Whether the True-Peak soft-knee output limiter protector is active.
  bool get limiterEnabled => _getLimiterEnabled();

  /// Clean synthesized container bytes containing all format headers, initial and trailing
  /// metadata tags (ID3v2, ID3v1, APEv2, Vorbis Comments, FLAC PICTURE, MP4 ilst/udta, etc.)
  /// with 0 seconds of audio samples, ready to be parsed in-memory by pub.dev packages
  /// (e.g. `audio_metadata_reader`, `id3tag`, etc.) without touching disk or network.
  ///
  /// Returns `null` if no media is loaded or if initial headers have not been received yet.
  Uint8List? get metaBytes => _getMetaBytes?.call();
}
