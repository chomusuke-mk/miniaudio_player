import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_item.dart';
import 'engine_state.dart' show EnginePhase;
import 'loop_mode.dart';
import 'player_state.dart' show PlaybackState;
import 'silence_skip_config.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

/// Reactive broadcast stream interface for observing [MiniaudioEngine] changes.
///
/// Mirrors every stream of [PlayerStream] (multiplexed from the active deck)
/// and adds fine-grained streams for queue mutations, active item changes,
/// shuffle/loop modes, crossfade settings, and finite-state-machine phases.
class EngineStream<T> {
  final StreamController<EnginePhase> _phaseController;
  final StreamController<Duration> _positionController;
  final StreamController<Duration> _durationController;
  final StreamController<bool> _playingController;
  final StreamController<bool> _bufferingController;
  final StreamController<bool> _completedController;
  final StreamController<bool> _openingController;
  final StreamController<PlaybackState> _playbackStateController;
  final StreamController<Duration> _bufferedPositionController;
  final StreamController<double> _bufferedPercentageController;
  final StreamController<BufferedRange> _bufferedRangeController;
  final StreamController<AudioTrackMetadata?> _trackMetadataController;
  final StreamController<double> _volumeController;
  final StreamController<double> _rateController;
  final StreamController<double> _pitchController;
  final StreamController<int> _bufferSizeController;
  final StreamController<int> _audioBitrateController;
  final StreamController<Equalizer> _equalizerController;
  final StreamController<AudioDevice> _audioDeviceController;
  final StreamController<bool> _skipSilenceController;
  final StreamController<SilenceSkipConfig> _silenceConfigController;
  final StreamController<Duration> _silenceSavedDurationController;
  final StreamController<VisualizerData> _visualizerController;
  final StreamController<bool> _visualizerEnabledController;
  final StreamController<double> _preampController;
  final StreamController<ReplayGainConfig> _replayGainController;
  final StreamController<double> _balanceController;
  final StreamController<bool> _monoController;
  final StreamController<CrossfeedMode> _crossfeedController;
  final StreamController<bool> _spatializerEnabledController;
  final StreamController<double> _spatializerWidthController;
  final StreamController<Reverb> _reverbController;
  final StreamController<bool> _limiterEnabledController;
  final StreamController<List<EngineItem<T>>> _queueController;
  final StreamController<int> _currentIndexController;
  final StreamController<EngineItem<T>?> _currentItemController;
  final StreamController<T?> _currentDataController;
  final StreamController<bool> _hasNextController;
  final StreamController<bool> _hasPreviousController;
  final StreamController<bool> _shuffleController;
  final StreamController<LoopMode> _loopModeController;
  final StreamController<CrossfadeConfig> _crossfadeConfigController;
  final StreamController<bool> _isCrossfadingController;
  final StreamController<bool> _volumeNormalizationController;
  final StreamController<bool> _infiniteMixController;
  final StreamController<double>? _defaultReplayGainController;
  final StreamController<double?>? _forcedReplayGainController;
  final StreamController<ReplayGainMode>? _replayGainModeController;
  final StreamController<Uint8List?>? _metaBytesController;

  /// Creates an [EngineStream] bound to internal broadcast controllers.
  EngineStream({
    required StreamController<EnginePhase> phaseController,
    required StreamController<Duration> positionController,
    required StreamController<Duration> durationController,
    required StreamController<bool> playingController,
    required StreamController<bool> bufferingController,
    required StreamController<bool> completedController,
    required StreamController<bool> openingController,
    required StreamController<PlaybackState> playbackStateController,
    required StreamController<Duration> bufferedPositionController,
    required StreamController<double> bufferedPercentageController,
    required StreamController<BufferedRange> bufferedRangeController,
    required StreamController<AudioTrackMetadata?> trackMetadataController,
    required StreamController<double> volumeController,
    required StreamController<double> rateController,
    required StreamController<double> pitchController,
    required StreamController<int> bufferSizeController,
    required StreamController<int> audioBitrateController,
    required StreamController<Equalizer> equalizerController,
    required StreamController<AudioDevice> audioDeviceController,
    required StreamController<bool> skipSilenceController,
    required StreamController<SilenceSkipConfig> silenceConfigController,
    required StreamController<Duration> silenceSavedDurationController,
    required StreamController<VisualizerData> visualizerController,
    required StreamController<bool> visualizerEnabledController,
    required StreamController<double> preampController,
    required StreamController<ReplayGainConfig> replayGainController,
    required StreamController<double> balanceController,
    required StreamController<bool> monoController,
    required StreamController<CrossfeedMode> crossfeedController,
    required StreamController<bool> spatializerEnabledController,
    required StreamController<double> spatializerWidthController,
    required StreamController<Reverb> reverbController,
    required StreamController<bool> limiterEnabledController,
    required StreamController<List<EngineItem<T>>> queueController,
    required StreamController<int> currentIndexController,
    required StreamController<EngineItem<T>?> currentItemController,
    required StreamController<T?> currentDataController,
    required StreamController<bool> hasNextController,
    required StreamController<bool> hasPreviousController,
    required StreamController<bool> shuffleController,
    required StreamController<LoopMode> loopModeController,
    required StreamController<CrossfadeConfig> crossfadeConfigController,
    required StreamController<bool> isCrossfadingController,
    required StreamController<bool> volumeNormalizationController,
    required StreamController<bool> infiniteMixController,
    StreamController<double>? defaultReplayGainController,
    StreamController<double?>? forcedReplayGainController,
    StreamController<ReplayGainMode>? replayGainModeController,
    StreamController<Uint8List?>? metaBytesController,
  })  : _phaseController = phaseController,
        _positionController = positionController,
        _durationController = durationController,
        _playingController = playingController,
        _bufferingController = bufferingController,
        _completedController = completedController,
        _openingController = openingController,
        _playbackStateController = playbackStateController,
        _bufferedPositionController = bufferedPositionController,
        _bufferedPercentageController = bufferedPercentageController,
        _bufferedRangeController = bufferedRangeController,
        _trackMetadataController = trackMetadataController,
        _volumeController = volumeController,
        _rateController = rateController,
        _pitchController = pitchController,
        _bufferSizeController = bufferSizeController,
        _audioBitrateController = audioBitrateController,
        _equalizerController = equalizerController,
        _audioDeviceController = audioDeviceController,
        _skipSilenceController = skipSilenceController,
        _silenceConfigController = silenceConfigController,
        _silenceSavedDurationController = silenceSavedDurationController,
        _visualizerController = visualizerController,
        _visualizerEnabledController = visualizerEnabledController,
        _preampController = preampController,
        _replayGainController = replayGainController,
        _balanceController = balanceController,
        _monoController = monoController,
        _crossfeedController = crossfeedController,
        _spatializerEnabledController = spatializerEnabledController,
        _spatializerWidthController = spatializerWidthController,
        _reverbController = reverbController,
        _limiterEnabledController = limiterEnabledController,
        _queueController = queueController,
        _currentIndexController = currentIndexController,
        _currentItemController = currentItemController,
        _currentDataController = currentDataController,
        _hasNextController = hasNextController,
        _hasPreviousController = hasPreviousController,
        _shuffleController = shuffleController,
        _loopModeController = loopModeController,
        _crossfadeConfigController = crossfadeConfigController,
        _isCrossfadingController = isCrossfadingController,
        _volumeNormalizationController = volumeNormalizationController,
        _infiniteMixController = infiniteMixController,
        _defaultReplayGainController = defaultReplayGainController,
        _forcedReplayGainController = forcedReplayGainController,
        _replayGainModeController = replayGainModeController,
        _metaBytesController = metaBytesController;

  // --------------------------------------------------------------------------
  // Base PlayerStream Broadcast Streams
  // --------------------------------------------------------------------------

  /// Broadcast stream of finite state machine [EnginePhase] transitions.
  Stream<EnginePhase> get phase => _phaseController.stream;

  /// Broadcast stream of current playback position of the active deck.
  Stream<Duration> get position => _positionController.stream;

  /// Broadcast stream of total audio duration of the active deck.
  Stream<Duration> get duration => _durationController.stream;

  /// Broadcast stream of active playback state (`true` when playing).
  Stream<bool> get playing => _playingController.stream;

  /// Broadcast stream of buffering state (`true` when waiting for network data).
  Stream<bool> get buffering => _bufferingController.stream;

  /// Broadcast stream of queue completion state (`true` when queue finishes).
  Stream<bool> get completed => _completedController.stream;

  /// Broadcast stream of opening state (`true` while preparing an audio source).
  Stream<bool> get opening => _openingController.stream;

  /// Broadcast stream of current playback lifecycle state.
  Stream<PlaybackState> get playbackState => _playbackStateController.stream;

  /// Broadcast stream of furthest continuous timestamp preloaded in RAM buffer.
  Stream<Duration> get bufferedPosition => _bufferedPositionController.stream;

  /// Broadcast stream of fraction (`0.0` to `1.0`) of total track buffered.
  Stream<double> get bufferedPercentage => _bufferedPercentageController.stream;

  /// Broadcast stream of sliding-window circular buffer telemetry metrics.
  Stream<BufferedRange> get bufferedRange => _bufferedRangeController.stream;

  /// Broadcast stream of resolved audio track metadata from the active deck.
  Stream<AudioTrackMetadata?> get trackMetadata =>
      _trackMetadataController.stream;

  /// Broadcast stream of master audio volume level (`0.0` to `2.0`).
  Stream<double> get volume => _volumeController.stream;

  /// Broadcast stream of playback speed multiplier (`0.1` to `4.0`).
  Stream<double> get rate => _rateController.stream;

  /// Broadcast stream of pitch multiplier (`0.5` to `2.0`).
  Stream<double> get pitch => _pitchController.stream;

  /// Broadcast stream of internal buffer size in frames.
  Stream<int> get bufferSize => _bufferSizeController.stream;

  /// Broadcast stream of audio nominal bitrate in bits per second (`bps`).
  Stream<int> get bitrate => _audioBitrateController.stream;

  /// Broadcast stream of 10-band graphic equalizer changes.
  Stream<Equalizer> get equalizer => _equalizerController.stream;

  /// Broadcast stream of active audio output device changes.
  Stream<AudioDevice> get audioDevice => _audioDeviceController.stream;

  /// Broadcast stream of silence skipping enabled state.
  Stream<bool> get skipSilence => _skipSilenceController.stream;

  /// Broadcast stream of complete silence skipping configuration changes.
  Stream<SilenceSkipConfig> get silenceConfig =>
      _silenceConfigController.stream;

  /// Broadcast stream of cumulative duration saved by skipping silence.
  Stream<Duration> get silenceSavedDuration =>
      _silenceSavedDurationController.stream;

  /// Broadcast stream of real-time visualizer spectrum and amplitude frames.
  Stream<VisualizerData> get visualizer => _visualizerController.stream;

  /// Broadcast stream of whether visualizer DSP extraction is currently active.
  Stream<bool> get visualizerEnabled => _visualizerEnabledController.stream;

  /// Broadcast stream of manual preamp gain changes in decibels.
  Stream<double> get preamp => _preampController.stream;

  /// Broadcast stream of active ReplayGain configuration changes.
  Stream<ReplayGainConfig> get replayGain => _replayGainController.stream;

  /// Broadcast stream of stereo balance / pan changes (`-1.0` to `+1.0`).
  Stream<double> get balance => _balanceController.stream;

  /// Broadcast stream of mono downmixing state changes.
  Stream<bool> get mono => _monoController.stream;

  /// Broadcast stream of binaural headphone crossfeed (`bs2b`) mode changes.
  Stream<CrossfeedMode> get crossfeed => _crossfeedController.stream;

  /// Broadcast stream of stereo widener / spatializer enabled state changes.
  Stream<bool> get spatializerEnabled => _spatializerEnabledController.stream;

  /// Broadcast stream of stereo widener width factor changes (`1.0` to `2.0`).
  Stream<double> get spatializerWidth => _spatializerWidthController.stream;

  /// Broadcast stream of algorithmic reverberation configuration changes.
  Stream<Reverb> get reverb => _reverbController.stream;

  /// Broadcast stream of True-Peak output limiter enabled state changes.
  Stream<bool> get limiterEnabled => _limiterEnabledController.stream;

  /// Broadcast stream emitting updated synthesized metadata container bytes
  /// whenever Head, Tail, or livestream ICY metadata changes.
  Stream<Uint8List?> get metaBytes =>
      _metaBytesController?.stream ?? const Stream.empty();

  // --------------------------------------------------------------------------
  // High-Level Queue, Navigation & Crossfade Broadcast Streams
  // --------------------------------------------------------------------------

  /// Broadcast stream emitting the active queue whenever items are loaded,
  /// reordered, inserted, appended, removed, shuffled, or cleared.
  Stream<List<EngineItem<T>>> get queue => _queueController.stream;

  /// Broadcast stream emitting the active zero-based queue index (`-1` when empty).
  Stream<int> get currentIndex => _currentIndexController.stream;

  /// Broadcast stream emitting the currently active [EngineItem] (or `null` when empty).
  Stream<EngineItem<T>?> get currentItem => _currentItemController.stream;

  /// Broadcast stream emitting the caller-owned domain payload (`currentItem?.data`).
  Stream<T?> get currentData => _currentDataController.stream;

  /// Broadcast stream emitting whether a subsequent item is available (`hasNext`).
  Stream<bool> get hasNext => _hasNextController.stream;

  /// Broadcast stream emitting whether stepping backward is available (`hasPrevious`).
  Stream<bool> get hasPrevious => _hasPreviousController.stream;

  /// Broadcast stream emitting shuffle mode state changes.
  Stream<bool> get shuffle => _shuffleController.stream;

  /// Broadcast stream emitting repeat policy ([LoopMode]) changes.
  Stream<LoopMode> get loopMode => _loopModeController.stream;

  /// Broadcast stream emitting [CrossfadeConfig] changes (automatic duration,
  /// manual duration, or curve).
  Stream<CrossfadeConfig> get crossfadeConfig =>
      _crossfadeConfigController.stream;

  /// Broadcast stream emitting whether a crossfade is currently in flight.
  Stream<bool> get isCrossfading => _isCrossfadingController.stream;

  /// Broadcast stream emitting whether per-item ReplayGain normalization is enabled.
  Stream<bool> get volumeNormalization =>
      _volumeNormalizationController.stream;

  /// Broadcast stream emitting the default fallback ReplayGain in decibels.
  Stream<double> get defaultReplayGain =>
      _defaultReplayGainController?.stream ?? const Stream.empty();

  /// Broadcast stream emitting forced uniform ReplayGain changes (`null` when track metadata is active).
  Stream<double?> get forcedReplayGain =>
      _forcedReplayGainController?.stream ?? const Stream.empty();

  /// Broadcast stream emitting [ReplayGainMode] transitions.
  Stream<ReplayGainMode> get replayGainMode =>
      _replayGainModeController?.stream ?? const Stream.empty();

  /// Broadcast stream emitting whether Infinite Mix proactive prefetching is enabled.
  Stream<bool> get infiniteMixEnabled => _infiniteMixController.stream;
}
