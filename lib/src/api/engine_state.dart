import 'dart:typed_data';

import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_item.dart';
import 'loop_mode.dart';
import 'player_state.dart' show PlaybackState;
import 'silence_skip_config.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

/// Explicit finite state machine (FSM) phases of [MiniaudioEngine].
///
/// Governs deterministic ownership of the active and standby [MiniaudioPlayer]
/// decks across queue navigation, automatic crossfades, manual skips, seeks,
/// and end-of-queue completion.
enum EnginePhase {
  /// Queue is empty or engine has been stopped/reset. Both decks are stopped at `0.0` volume.
  idle,

  /// Engine is preparing/opening a target [EngineItem] on a deck.
  loading,

  /// Single active deck is playing at master volume; standby deck is stopped and silent.
  playing,

  /// Playback (or an active crossfade) is paused at the current position.
  paused,

  /// Tentative automatic overlap near the end of the active track.
  ///
  /// The outgoing deck still represents the current queue index while the
  /// incoming standby deck fades in with the candidate next item.
  autoCrossfading,

  /// Committed overlap initiated by `next()`, `previous()`, `skipToIndex()`,
  /// or promoted from [autoCrossfading].
  ///
  /// The queue index has already advanced to the incoming deck (`activeDeck`),
  /// which fades in while `standbyDeck` fades out.
  manualCrossfading,

  /// Reached the end of the queue in [LoopMode.off] (and Infinite Mix is off or exhausted).
  completed,

  /// Unrecoverable error when all candidate items in the queue fail to open.
  error,

  /// Engine has been permanently disposed and native resources released.
  disposed,
}

/// Synchronous state snapshot interface for [MiniaudioEngine].
///
/// Includes every property of [PlayerState] (delegated to the currently active
/// deck and engine-wide DSP state) plus full queue, navigation, crossfade, and
/// finite-state-machine properties.
class EngineState<T> {
  final EnginePhase Function() _getPhase;
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
  final int Function() _getSampleRate;
  final int Function() _getChannels;
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
  final List<EngineItem<T>> Function() _getQueue;
  final List<EngineItem<T>> Function() _getOriginalQueue;
  final int Function() _getCurrentIndex;
  final EngineItem<T>? Function() _getCurrentItem;
  final EngineItem<T>? Function() _getNextItem;
  final bool Function() _getHasNext;
  final bool Function() _getHasPrevious;
  final bool Function() _getShuffle;
  final LoopMode Function() _getLoopMode;
  final CrossfadeConfig Function() _getCrossfadeConfig;
  final bool Function() _getIsCrossfading;
  final double Function() _getCrossfadeProgress;
  final bool Function() _getVolumeNormalization;
  final bool Function() _getInfiniteMixEnabled;
  final bool Function() _getIsLiveStream;
  final double Function() _getDefaultReplayGain;
  final double? Function() _getForcedReplayGain;
  final ReplayGainMode Function() _getReplayGainMode;
  final Uint8List? Function()? _getMetaBytes;

  /// Creates an [EngineState] view bound to [MiniaudioEngine] state getters.
  EngineState({
    required EnginePhase Function() getPhase,
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
    required int Function() getSampleRate,
    required int Function() getChannels,
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
    required List<EngineItem<T>> Function() getQueue,
    required List<EngineItem<T>> Function() getOriginalQueue,
    required int Function() getCurrentIndex,
    required EngineItem<T>? Function() getCurrentItem,
    required EngineItem<T>? Function() getNextItem,
    required bool Function() getHasNext,
    required bool Function() getHasPrevious,
    required bool Function() getShuffle,
    required LoopMode Function() getLoopMode,
    required CrossfadeConfig Function() getCrossfadeConfig,
    required bool Function() getIsCrossfading,
    required double Function() getCrossfadeProgress,
    required bool Function() getVolumeNormalization,
    required bool Function() getInfiniteMixEnabled,
    required bool Function() getIsLiveStream,
    double Function()? getDefaultReplayGain,
    double? Function()? getForcedReplayGain,
    ReplayGainMode Function()? getReplayGainMode,
    Uint8List? Function()? getMetaBytes,
  })  : _getPhase = getPhase,
        _getPosition = getPosition,
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
        _getSampleRate = getSampleRate,
        _getChannels = getChannels,
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
        _getQueue = getQueue,
        _getOriginalQueue = getOriginalQueue,
        _getCurrentIndex = getCurrentIndex,
        _getCurrentItem = getCurrentItem,
        _getNextItem = getNextItem,
        _getHasNext = getHasNext,
        _getHasPrevious = getHasPrevious,
        _getShuffle = getShuffle,
        _getLoopMode = getLoopMode,
        _getCrossfadeConfig = getCrossfadeConfig,
        _getIsCrossfading = getIsCrossfading,
        _getCrossfadeProgress = getCrossfadeProgress,
        _getVolumeNormalization = getVolumeNormalization,
        _getInfiniteMixEnabled = getInfiniteMixEnabled,
        _getIsLiveStream = getIsLiveStream,
        _getDefaultReplayGain = getDefaultReplayGain ?? (() => 0.0),
        _getForcedReplayGain = getForcedReplayGain ?? (() => null),
        _getReplayGainMode = getReplayGainMode ??
            (() => !getVolumeNormalization()
                ? ReplayGainMode.disabled
                : ((getForcedReplayGain != null && getForcedReplayGain() != null)
                    ? ReplayGainMode.forced
                    : ReplayGainMode.track)),
        _getMetaBytes = getMetaBytes;

  // --------------------------------------------------------------------------
  // Base PlayerState Properties
  // --------------------------------------------------------------------------

  /// Current finite state machine phase of [MiniaudioEngine].
  EnginePhase get phase => _getPhase();

  /// Current playback position of the active deck.
  Duration get position => _getPosition();

  /// Total duration of the currently active audio source (`Duration.zero` for livestreams).
  Duration get duration => _getDuration();

  /// Normalized progress (`0.0` to `1.0`) of the current track.
  double get progress {
    final durMs = duration.inMilliseconds;
    if (durMs <= 0) return 0.0;
    return (position.inMilliseconds / durMs).clamp(0.0, 1.0);
  }

  /// Remaining duration of the current track.
  Duration get remaining {
    final dur = duration;
    final pos = position;
    return dur > pos ? dur - pos : Duration.zero;
  }

  /// Whether playback is currently active.
  bool get playing => _getPlaying();

  /// Whether the active deck is currently buffering network data.
  bool get buffering => _getBuffering();

  /// Whether the entire queue has finished playback.
  bool get completed => _getCompleted();

  /// Whether an audio source is currently being prepared/opened.
  bool get opening => _getOpening();

  /// Whether engine is currently paused.
  bool get isPaused => playbackState == PlaybackState.paused;

  /// Whether engine is currently stopped.
  bool get isStopped => playbackState == PlaybackState.stopped;

  /// Whether engine is currently in an error state.
  bool get isError => playbackState == PlaybackState.error;

  /// Current lifecycle state derived from the engine state machine.
  PlaybackState get playbackState => _getPlaybackState();

  /// Furthest continuous timestamp preloaded in the active deck's RAM buffer.
  Duration get bufferedPosition => _getBufferedPosition();

  /// Fraction (`0.0` to `1.0`) of the total track loaded into the buffer.
  double get bufferedPercentage => _getBufferedPercentage();

  /// Comprehensive sliding-window circular buffer telemetry metrics.
  BufferedRange get bufferedRange => _getBufferedRange();

  /// Current audio track metadata from the active deck, or `null` if idle.
  AudioTrackMetadata? get trackMetadata => _getTrackMetadata();

  /// Master audio volume level (`0.0` to `2.0`, default `1.0` = unity gain).
  double get volume => _getVolume();

  /// Current playback speed multiplier (`0.1` to `4.0`, default `1.0`).
  double get rate => _getRate();

  /// Current pitch multiplier (`0.5` to `2.0`, default `1.0`).
  double get pitch => _getPitch();

  /// Internal native buffer size in frames (`0` = native default).
  int get bufferSize => _getBufferSize();

  /// Current audio nominal bitrate in bits per second (`bps`), or `0` if unknown.
  int get bitrate => _getAudioBitrate();

  /// Native audio sampling rate in Hz of the active deck, or `0` if idle.
  int get sampleRate => _getSampleRate();

  /// Channel count of the active deck (e.g. `1` for mono, `2` for stereo), or `0` if idle.
  int get channels => _getChannels();

  /// Current 10-band graphic equalizer configuration.
  Equalizer get equalizer => _getEqualizer();

  /// Currently selected audio output device.
  AudioDevice get audioDevice => _getAudioDevice();

  /// Whether silence skipping is currently enabled.
  bool get skipSilence => _getSkipSilence();

  /// Current operational mode for silence skipping.
  SilenceSkipMode get silenceSkipMode => _getSilenceSkipMode();

  /// Complete silence detection and removal configuration.
  SilenceSkipConfig get silenceConfig => _getSilenceConfig();

  /// Cumulative playback time saved by skipping silent segments on the active deck.
  Duration get silenceSavedDuration => _getSilenceSavedDuration();

  /// Latest real-time visualizer spectrum and amplitude frame from the active deck.
  VisualizerData get visualizer => _getVisualizer();

  /// Whether real-time visualizer DSP extraction is currently active.
  bool get visualizerEnabled => _getVisualizerEnabled();

  /// Manual preamp gain in decibels (`-12.0` to `+12.0` dB).
  double get preamp => _getPreamp();

  /// Active ReplayGain / loudness normalization configuration on the active deck.
  ReplayGainConfig get replayGain => _getReplayGain();

  /// Stereo balance / pan (`-1.0` full left, `0.0` center, `+1.0` full right).
  double get balance => _getBalance();

  /// Whether mono downmixing is enabled.
  bool get mono => _getMono();

  /// Current binaural headphone crossfeed mode (`bs2b`).
  CrossfeedMode get crossfeed => _getCrossfeed();

  /// Whether the stereo widener / spatializer is enabled.
  bool get spatializerEnabled => _getSpatializerEnabled();

  /// Stereo widener width factor (`1.0` to `2.0`).
  double get spatializerWidth => _getSpatializerWidth();

  /// Current algorithmic reverberation configuration.
  Reverb get reverb => _getReverb();

  /// Whether the True-Peak output limiter is enabled.
  bool get limiterEnabled => _getLimiterEnabled();

  /// Synthesized metadata container bytes ([Uint8List]) containing only
  /// metadata (Head + Tail) with 0-byte audio for safe, instant parsing by
  /// pub.dev audio metadata libraries.
  Uint8List? get metaBytes => _getMetaBytes?.call();

  // --------------------------------------------------------------------------
  // High-Level Queue, Navigation & Crossfade Properties
  // --------------------------------------------------------------------------

  /// Read-only O(1) snapshot of the active playback queue.
  List<EngineItem<T>> get queue => _getQueue();

  /// Read-only O(1) snapshot of the original un-shuffled queue sequence.
  List<EngineItem<T>> get originalQueue => _getOriginalQueue();

  /// Current zero-based index into [queue], or `-1` if the queue is empty.
  int get currentIndex => _getCurrentIndex();

  /// Currently active [EngineItem], or `null` if the queue is empty.
  EngineItem<T>? get currentItem => _getCurrentItem();

  /// Caller-supplied domain payload of [currentItem] (`currentItem?.data`).
  T? get currentData => _getCurrentItem()?.data;

  /// Candidate next [EngineItem] according to [loopMode], or `null` if none.
  EngineItem<T>? get nextItem => _getNextItem();

  /// Whether there is a next item available in the queue (considering [loopMode] and [infiniteMixEnabled]).
  bool get hasNext => _getHasNext();

  /// Whether stepping backward is available (either to a prior item or to restart the current track after `3s`).
  bool get hasPrevious => _getHasPrevious();

  /// Whether the queue is currently in shuffled order.
  bool get shuffle => _getShuffle();

  /// Current repeat policy ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  LoopMode get loopMode => _getLoopMode();

  /// Current automatic and manual crossfade configuration.
  CrossfadeConfig get crossfadeConfig => _getCrossfadeConfig();

  /// Automatic crossfade duration (`crossfadeConfig.duration`).
  Duration get crossfadeDuration => _getCrossfadeConfig().duration;

  /// Manual crossfade duration (`crossfadeConfig.manualDuration`).
  Duration get manualCrossfadeDuration => _getCrossfadeConfig().manualDuration;

  /// Whether a crossfade (automatic or manual) is currently in flight.
  bool get isCrossfading => _getIsCrossfading();

  /// Current progress (`0.0` to `1.0`) of an active crossfade, or `0.0` if none.
  double get crossfadeProgress => _getCrossfadeProgress();

  /// Whether automatic per-item ReplayGain normalization is enabled.
  bool get volumeNormalization => _getVolumeNormalization();

  /// Default fallback ReplayGain in decibels applied to queue items that lack
  /// per-track metadata.
  double get defaultReplayGain => _getDefaultReplayGain();

  /// Forced uniform ReplayGain in decibels applied across all queue items, or
  /// `null` if per-track metadata is respected.
  double? get forcedReplayGain => _getForcedReplayGain();

  /// Current ReplayGain operational mode ([ReplayGainMode.disabled],
  /// [ReplayGainMode.track], or [ReplayGainMode.forced]).
  ReplayGainMode get replayGainMode => _getReplayGainMode();

  /// Whether Infinite Mix proactive lookahead prefetching is enabled.
  bool get infiniteMixEnabled => _getInfiniteMixEnabled();

  /// Whether the currently active item is a continuous livestream.
  bool get isLiveStream => _getIsLiveStream();
}
