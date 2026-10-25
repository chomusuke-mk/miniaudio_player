import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/internal_crossfade_controller.dart';
import '../engine/internal_queue_manager.dart';
import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_action.dart';
import 'engine_item.dart';
import 'engine_state.dart';
import 'engine_stream.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'player_state.dart' show PlaybackState;
import 'silence_skip_config.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

/// High-level dual-deck audio engine with integrated queue management,
/// Fisher-Yates shuffle, continuous equal-power/linear crossfade, per-track
/// ReplayGain normalization, and studio DSP orchestration.
///
/// [MiniaudioEngine] exposes the exact same tripartite ergonomic architecture
/// as [MiniaudioPlayer]:
/// - [action] ([EngineAction]): Asynchronous transport, queue, crossfade, and DSP commands.
/// - [state] ([EngineState]): Instantaneous synchronous state snapshot getters.
/// - [stream] ([EngineStream]): Fine-grained broadcast streams per property.
///
/// ### Finite State Machine (FSM) Architecture
/// All operations are serialized through a FIFO command lane and governed by
/// an explicit [EnginePhase] state machine:
/// - **Single Ownership of Deck Lifecycle:** Only [MiniaudioEngine] invokes
///   `open`, `play`, `pause`, `stop`, or `seek` on the two underlying
///   [MiniaudioPlayer] decks (`_playerA` and `_playerB`).
/// - **Clean Standby Invariant:** Before any transition reuses the standby
///   deck (including rapid `next() -> previous()` sequences), any in-flight
///   transition is deterministically settled and the standby deck is guaranteed
///   stopped at `0.0` volume.
/// - **Zero Dirty-State Hacks:** Because `MiniaudioPlayer.action.open` resets
///   the native decoder to frame `0` upon opening, [MiniaudioEngine] never
///   executes redundant `seek(Duration.zero)` calls during track preparation,
///   ensuring seamless compatibility with local files, progressive HTTP/HTTPS
///   streams, and infinite livestreams ([LiveStreamAudioSource]).
class MiniaudioEngine<T> {
  /// Tolerance near track end used to verify genuine completion vs stale events.
  static const Duration _completionTolerance = Duration(seconds: 1);

  final MiniaudioPlayer _playerA;
  final MiniaudioPlayer _playerB;
  final bool _ownsPlayers;

  late MiniaudioPlayer _activePlayer;
  late MiniaudioPlayer _standbyPlayer;

  final InternalQueueManager<T> _queueManager;
  final InternalCrossfadeController _crossfade;

  // --------------------------------------------------------------------------
  // Finite State Machine (FSM) Fields
  // --------------------------------------------------------------------------

  EnginePhase _phase = EnginePhase.idle;

  /// Monotonic state-machine epoch incremented on every deck swap, hard load,
  /// or transition change to invalidate stale asynchronous callbacks.
  int _epoch = 0;

  /// Epoch for which a track-end completion handler has already been scheduled.
  int? _scheduledCompletionEpoch;

  /// Guard preventing multiple concurrent automatic crossfade preparations.
  bool _autoStartScheduled = false;

  /// Target item of a currently running or preparing automatic crossfade.
  EngineItem<T>? _autoTarget;

  /// Item that failed to open during an automatic crossfade attempt in the
  /// current epoch (prevents retrying on every `25ms` position tick).
  EngineItem<T>? _failedAutoTarget;

  /// Serialized FIFO command lane tail.
  Future<void> _commandTail = Future<void>.value();

  StreamSubscription<EngineItem<T>?>? _nextCandidateSubscription;
  final List<StreamSubscription<dynamic>> _activeDeckSubscriptions = [];

  // --------------------------------------------------------------------------
  // Retained Engine-Wide Audio & DSP Configuration
  // --------------------------------------------------------------------------

  CrossfadeConfig _crossfadeConfig;
  double _masterVolume = 1.0;
  double _playbackRate = 1.0;
  double _playbackPitch = 1.0;
  int _bufferSize;
  Equalizer _equalizer = Equalizer.flat;
  Reverb _reverb = Reverb.off;
  AudioDevice _audioDevice;
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();
  bool _volumeNormalization = true;
  double _preampDb = 0.0;
  double _balance = 0.0;
  bool _mono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  double _spatializerWidth = 1.0;
  bool _limiterEnabled = true;

  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;

  bool get _shouldEnableVisualizerOnActive =>
      _manualVisualizerOverride ?? _hasVisualizerListeners;

  // --------------------------------------------------------------------------
  // Broadcast Stream Controllers & Distinct Emission Cache
  // --------------------------------------------------------------------------

  final StreamController<EnginePhase> _phaseController =
      StreamController<EnginePhase>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _completedController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _openingController =
      StreamController<bool>.broadcast();
  final StreamController<PlaybackState> _playbackStateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<Duration> _bufferedPositionController =
      StreamController<Duration>.broadcast();
  final StreamController<double> _bufferedPercentageController =
      StreamController<double>.broadcast();
  final StreamController<BufferedRange> _bufferedRangeController =
      StreamController<BufferedRange>.broadcast();
  final StreamController<AudioTrackMetadata?> _trackMetadataController =
      StreamController<AudioTrackMetadata?>.broadcast();
  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();
  final StreamController<double> _rateController =
      StreamController<double>.broadcast();
  final StreamController<double> _pitchController =
      StreamController<double>.broadcast();
  final StreamController<int> _bufferSizeController =
      StreamController<int>.broadcast();
  final StreamController<int> _audioBitrateController =
      StreamController<int>.broadcast();
  final StreamController<Equalizer> _equalizerController =
      StreamController<Equalizer>.broadcast();
  final StreamController<AudioDevice> _audioDeviceController =
      StreamController<AudioDevice>.broadcast();
  final StreamController<bool> _skipSilenceController =
      StreamController<bool>.broadcast();
  final StreamController<SilenceSkipConfig> _silenceConfigController =
      StreamController<SilenceSkipConfig>.broadcast();
  final StreamController<Duration> _silenceSavedDurationController =
      StreamController<Duration>.broadcast();
  late final StreamController<VisualizerData> _visualizerController;
  final StreamController<bool> _visualizerEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> _preampController =
      StreamController<double>.broadcast();
  final StreamController<ReplayGainConfig> _replayGainController =
      StreamController<ReplayGainConfig>.broadcast();
  final StreamController<double> _balanceController =
      StreamController<double>.broadcast();
  final StreamController<bool> _monoController =
      StreamController<bool>.broadcast();
  final StreamController<CrossfeedMode> _crossfeedController =
      StreamController<CrossfeedMode>.broadcast();
  final StreamController<bool> _spatializerEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> _spatializerWidthController =
      StreamController<double>.broadcast();
  final StreamController<Reverb> _reverbController =
      StreamController<Reverb>.broadcast();
  final StreamController<bool> _limiterEnabledController =
      StreamController<bool>.broadcast();

  final StreamController<List<EngineItem<T>>> _queueController =
      StreamController<List<EngineItem<T>>>.broadcast();
  final StreamController<int> _currentIndexController =
      StreamController<int>.broadcast();
  final StreamController<EngineItem<T>?> _currentItemController =
      StreamController<EngineItem<T>?>.broadcast();
  final StreamController<T?> _currentDataController =
      StreamController<T?>.broadcast();
  final StreamController<bool> _hasNextController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _hasPreviousController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _shuffleController =
      StreamController<bool>.broadcast();
  final StreamController<LoopMode> _loopModeController =
      StreamController<LoopMode>.broadcast();
  final StreamController<CrossfadeConfig> _crossfadeConfigController =
      StreamController<CrossfadeConfig>.broadcast();
  final StreamController<bool> _isCrossfadingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _volumeNormalizationController =
      StreamController<bool>.broadcast();
  final StreamController<bool> _infiniteMixController =
      StreamController<bool>.broadcast();
  final StreamController<Uint8List?> _metaBytesController =
      StreamController<Uint8List?>.broadcast();

  // Distinct emission caches to prevent duplicate stream events
  List<EngineItem<T>>? _lastEmittedQueue;
  int _lastEmittedIndex = -1;
  EngineItem<T>? _lastEmittedItem;
  bool _lastEmittedHasNext = false;
  bool _lastEmittedHasPrevious = false;
  bool _lastEmittedShuffle = false;
  LoopMode _lastEmittedLoopMode = LoopMode.off;
  bool _lastEmittedIsCrossfading = false;
  bool _lastEmittedPlaying = false;
  bool _lastEmittedBuffering = false;
  bool _lastEmittedCompleted = false;
  bool _lastEmittedOpening = false;
  PlaybackState _lastEmittedPlaybackState = PlaybackState.stopped;
  Duration _lastEmittedDuration = Duration.zero;

  /// Action interface for controlling playback, queue, crossfade, and DSP.
  late final EngineAction<T> action;

  /// Reactive broadcast stream interface for observing engine state changes.
  late final EngineStream<T> stream;

  /// Synchronous state snapshot interface.
  late final EngineState<T> state;

  /// Creates a [MiniaudioEngine] instance coordinating two [MiniaudioPlayer] decks.
  ///
  /// - [bufferSize]: Optional internal native buffer size in frames.
  /// - [defaultAudioDevice]: Optional initial output audio device.
  /// - [crossfadeConfig]: Initial automatic and manual crossfade settings.
  /// - [infiniteMixProvider]: Optional async provider supplying items when the
  ///   queue reaches the end in [LoopMode.off] with Infinite Mix enabled.
  /// - [crossfadeTickerInterval]: Gain interpolation tick interval (default: `25ms`).
  /// - [random]: Optional random number generator for deterministic shuffle testing.
  /// - [playerA], [playerB]: Optional pre-constructed [MiniaudioPlayer] instances.
  MiniaudioEngine({
    int? bufferSize,
    AudioDevice? defaultAudioDevice,
    CrossfadeConfig? crossfadeConfig,
    InfiniteMixProvider<T>? infiniteMixProvider,
    Duration crossfadeTickerInterval = const Duration(milliseconds: 25),
    math.Random? random,
    MiniaudioPlayer? playerA,
    MiniaudioPlayer? playerB,
  })  : _ownsPlayers = playerA == null && playerB == null,
        _playerA = playerA ??
            MiniaudioPlayer(
              bufferSize: bufferSize,
              defaultAudioDevice: defaultAudioDevice,
            ),
        _playerB = playerB ??
            MiniaudioPlayer(
              bufferSize: bufferSize,
              defaultAudioDevice: defaultAudioDevice,
            ),
        _bufferSize =
            bufferSize ?? MiniaudioPlayer.globalConfig.defaultBufferSize,
        _audioDevice = defaultAudioDevice ??
            MiniaudioPlayer.globalConfig.defaultAudioDevice,
        _crossfadeConfig = crossfadeConfig ?? CrossfadeConfig(),
        _queueManager = InternalQueueManager<T>(
          infiniteMixProvider: infiniteMixProvider,
          random: random,
        ),
        _crossfade = InternalCrossfadeController(
          tickerInterval: crossfadeTickerInterval,
        ) {
    _activePlayer = _playerA;
    _standbyPlayer = _playerB;

    _visualizerController = StreamController<VisualizerData>.broadcast(
      onListen: () {
        _hasVisualizerListeners = true;
        _syncDeckVisualizerStates();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _syncDeckVisualizerStates();
      },
    );

    action = EngineAction<T>(this);

    stream = EngineStream<T>(
      phaseController: _phaseController,
      positionController: _positionController,
      durationController: _durationController,
      playingController: _playingController,
      bufferingController: _bufferingController,
      completedController: _completedController,
      openingController: _openingController,
      playbackStateController: _playbackStateController,
      bufferedPositionController: _bufferedPositionController,
      bufferedPercentageController: _bufferedPercentageController,
      bufferedRangeController: _bufferedRangeController,
      trackMetadataController: _trackMetadataController,
      volumeController: _volumeController,
      rateController: _rateController,
      pitchController: _pitchController,
      bufferSizeController: _bufferSizeController,
      audioBitrateController: _audioBitrateController,
      equalizerController: _equalizerController,
      audioDeviceController: _audioDeviceController,
      skipSilenceController: _skipSilenceController,
      silenceConfigController: _silenceConfigController,
      silenceSavedDurationController: _silenceSavedDurationController,
      visualizerController: _visualizerController,
      visualizerEnabledController: _visualizerEnabledController,
      preampController: _preampController,
      replayGainController: _replayGainController,
      balanceController: _balanceController,
      monoController: _monoController,
      crossfeedController: _crossfeedController,
      spatializerEnabledController: _spatializerEnabledController,
      spatializerWidthController: _spatializerWidthController,
      reverbController: _reverbController,
      limiterEnabledController: _limiterEnabledController,
      queueController: _queueController,
      currentIndexController: _currentIndexController,
      currentItemController: _currentItemController,
      currentDataController: _currentDataController,
      hasNextController: _hasNextController,
      hasPreviousController: _hasPreviousController,
      shuffleController: _shuffleController,
      loopModeController: _loopModeController,
      crossfadeConfigController: _crossfadeConfigController,
      isCrossfadingController: _isCrossfadingController,
      volumeNormalizationController: _volumeNormalizationController,
      infiniteMixController: _infiniteMixController,
      metaBytesController: _metaBytesController,
    );

    state = EngineState<T>(
      getPhase: () => _phase,
      getPosition: _resolvePosition,
      getDuration: () => _activePlayer.state.duration,
      getPlaying: _resolvePlaying,
      getBuffering: () => _activePlayer.state.buffering,
      getCompleted: () => _phase == EnginePhase.completed,
      getOpening: () =>
          _phase == EnginePhase.loading || _activePlayer.state.opening,
      getPlaybackState: _resolvePlaybackState,
      getBufferedPosition: () => _activePlayer.state.bufferedPosition,
      getBufferedPercentage: () => _activePlayer.state.bufferedPercentage,
      getBufferedRange: () => _activePlayer.state.bufferedRange,
      getTrackMetadata: () => _activePlayer.state.trackMetadata,
      getVolume: () => _masterVolume,
      getRate: () => _playbackRate,
      getPitch: () => _playbackPitch,
      getBufferSize: () => _bufferSize,
      getAudioBitrate: () => _activePlayer.state.audioBitrate,
      getSampleRate: () => _activePlayer.sampleRate,
      getChannels: () => _activePlayer.channels,
      getEqualizer: () => _equalizer,
      getAudioDevice: () => _activePlayer.state.audioDevice,
      getSkipSilence: () => _silenceConfig.mode != SilenceSkipMode.disabled,
      getSilenceSkipMode: () => _silenceConfig.mode,
      getSilenceConfig: () => _silenceConfig,
      getSilenceSavedDuration: () => _activePlayer.state.silenceSavedDuration,
      getVisualizer: () => _shouldEnableVisualizerOnActive
          ? _activePlayer.state.visualizer
          : VisualizerData.empty(),
      getVisualizerEnabled: () => _shouldEnableVisualizerOnActive,
      getPreamp: () => _preampDb,
      getReplayGain: () => _activePlayer.state.replayGain,
      getBalance: () => _balance,
      getMono: () => _mono,
      getCrossfeed: () => _crossfeed,
      getSpatializerEnabled: () => _spatializerEnabled,
      getSpatializerWidth: () => _spatializerWidth,
      getReverb: () => _reverb,
      getLimiterEnabled: () => _limiterEnabled,
      getQueue: () => _queueManager.activeQueue,
      getOriginalQueue: () => _queueManager.originalQueue,
      getCurrentIndex: () => _queueManager.currentIndex,
      getCurrentItem: () => _queueManager.currentItem,
      getNextItem: () => _queueManager.peekNext(distinct: false),
      getHasNext: () => _queueManager.hasNext,
      getHasPrevious: _resolveHasPrevious,
      getShuffle: () => _queueManager.isShuffled,
      getLoopMode: () => _queueManager.loopMode,
      getCrossfadeConfig: () => _crossfadeConfig,
      getIsCrossfading: () =>
          _phase == EnginePhase.autoCrossfading ||
          _phase == EnginePhase.manualCrossfading,
      getCrossfadeProgress: () => _crossfade.progress,
      getVolumeNormalization: () => _volumeNormalization,
      getInfiniteMixEnabled: () => _queueManager.infiniteMixEnabled,
      getIsLiveStream: _resolveIsLiveStream,
      getMetaBytes: () => _activePlayer.state.metaBytes,
    );

    _nextCandidateSubscription =
        _queueManager.nextItemStream.listen(_onNextCandidateChanged);
    _queueManager.onQueueMutated = _onBackgroundQueueMutated;

    _syncDeckVisualizerStates();
    _bindActiveDeck();
  }

  /// Active network audio streamer on the currently active deck, if any.
  dynamic get activeStreamer => _activePlayer.streamer;

  /// Whether this engine instance has been disposed.
  bool get isDisposed => _phase == EnginePhase.disposed;

  /// Ensures that the engine has not been disposed.
  void ensureNotDisposed() {
    if (isDisposed) {
      throw const MiniaudioPlayerException('MiniaudioEngine is already disposed');
    }
  }

  // --------------------------------------------------------------------------
  // Synchronous State Resolvers
  // --------------------------------------------------------------------------

  Duration _resolvePosition() {
    if (_phase == EnginePhase.completed) {
      final dur = _activePlayer.state.duration;
      return dur > Duration.zero ? dur : _activePlayer.state.position;
    }
    return _activePlayer.state.position;
  }

  bool _resolvePlaying() {
    return switch (_phase) {
      EnginePhase.playing ||
      EnginePhase.autoCrossfading ||
      EnginePhase.manualCrossfading =>
        !_crossfade.isPaused && _activePlayer.state.playing,
      _ => false,
    };
  }

  PlaybackState _resolvePlaybackState() {
    return switch (_phase) {
      EnginePhase.idle || EnginePhase.disposed => PlaybackState.stopped,
      EnginePhase.loading => PlaybackState.opening,
      EnginePhase.completed => PlaybackState.completed,
      EnginePhase.error => PlaybackState.error,
      EnginePhase.paused => PlaybackState.paused,
      EnginePhase.playing ||
      EnginePhase.autoCrossfading ||
      EnginePhase.manualCrossfading =>
        _activePlayer.state.buffering
            ? PlaybackState.buffering
            : (_resolvePlaying()
                ? PlaybackState.playing
                : PlaybackState.paused),
    };
  }

  bool _resolveIsLiveStream() {
    final item = _queueManager.currentItem;
    if (item != null && item.isLiveStream) return true;
    return _activePlayer.state.trackMetadata?.isLiveStream ?? false;
  }

  bool _resolveHasPrevious() {
    if (_queueManager.isEmpty) return false;
    if (_queueManager.hasPrevious) return true;
    return !_resolveIsLiveStream() &&
        _resolvePosition() > InternalQueueManager.restartThreshold;
  }

  // --------------------------------------------------------------------------
  // Finite State Machine (FSM) Transitions & Serialization
  // --------------------------------------------------------------------------

  void _setPhase(EnginePhase nextPhase) {
    if (_phase == EnginePhase.disposed) return;
    final prevPhase = _phase;
    final wasCrossfading = prevPhase == EnginePhase.autoCrossfading ||
        prevPhase == EnginePhase.manualCrossfading;
    final nowCrossfading = nextPhase == EnginePhase.autoCrossfading ||
        nextPhase == EnginePhase.manualCrossfading;

    _phase = nextPhase;

    if (prevPhase != nextPhase && !_phaseController.isClosed) {
      _phaseController.add(nextPhase);
    }
    if (wasCrossfading != nowCrossfading &&
        _lastEmittedIsCrossfading != nowCrossfading) {
      _lastEmittedIsCrossfading = nowCrossfading;
      if (!_isCrossfadingController.isClosed) {
        _isCrossfadingController.add(nowCrossfading);
      }
    }

    _emitDerivedTransportState();
  }

  void _bumpEpoch() {
    _epoch++;
    _scheduledCompletionEpoch = null;
    _failedAutoTarget = null;
  }

  Future<R> _serialize<R>(Future<R> Function() action) {
    final next = _commandTail.then((_) async {
      if (isDisposed) {
        throw const MiniaudioPlayerException('MiniaudioEngine is disposed');
      }
      return await action();
    });
    _commandTail = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  void _scheduleInternal(Future<void> Function() task) {
    if (isDisposed) return;
    _serialize(() async {
      if (isDisposed) return;
      await task();
    }).ignore();
  }

  /// Synchronously cancels the crossfade ticker and deterministically settles
  /// the standby deck into a clean `stopped` state at `0.0` volume before a
  /// new command runs.
  ///
  /// - If `_phase == EnginePhase.autoCrossfading` (tentative transition where
  ///   the queue has NOT yet advanced), reverts to the outgoing `_activePlayer`
  ///   and stops `_standbyPlayer`.
  /// - If `_phase == EnginePhase.manualCrossfading` (committed transition where
  ///   the queue HAS already advanced to `_activePlayer`), finalizes
  ///   `_activePlayer` at `_masterVolume` and stops `_standbyPlayer`.
  Future<void> _settleActiveTransition() async {
    final currentPhase = _phase;
    if (currentPhase != EnginePhase.autoCrossfading &&
        currentPhase != EnginePhase.manualCrossfading) {
      _crossfade.cancel();
      _autoTarget = null;
      return;
    }

    final wasPaused = _crossfade.isPaused;
    _crossfade.cancel();
    _autoTarget = null;

    await _resetDeckToStandby(_standbyPlayer);
    if (!_activePlayer.isDisposed) {
      try {
        await _activePlayer.action.setVolume(_masterVolume);
      } catch (_) {}
    }

    if (currentPhase == EnginePhase.autoCrossfading &&
        _activePlayer.state.completed) {
      _setPhase(
        wasPaused ? EnginePhase.paused : EnginePhase.playing,
      );
      _scheduleCompletion(verifyPosition: false);
      return;
    }

    _setPhase(
      wasPaused || !_activePlayer.state.playing
          ? EnginePhase.paused
          : EnginePhase.playing,
    );
  }

  /// Ensures [deck] is completely silent (`volume = 0.0`) and stopped (`stop()`)
  /// with visualizer DSP disabled.
  Future<void> _resetDeckToStandby(MiniaudioPlayer deck) async {
    if (deck.isDisposed) return;
    deck.setManualVisualizerOverride(false);
    try {
      await deck.action.setVolume(0.0);
    } catch (_) {}
    try {
      await deck.action.stop();
    } catch (_) {}
  }

  void _swapDecks() {
    final prevActive = _activePlayer;
    _activePlayer = _standbyPlayer;
    _standbyPlayer = prevActive;
    _bumpEpoch();
    _syncDeckVisualizerStates();
    _bindActiveDeck();
  }

  void _syncDeckVisualizerStates() {
    if (isDisposed) return;
    final enableActive = _shouldEnableVisualizerOnActive;
    if (!_activePlayer.isDisposed) {
      _activePlayer.setManualVisualizerOverride(enableActive);
    }
    if (!_standbyPlayer.isDisposed) {
      _standbyPlayer.setManualVisualizerOverride(false);
    }
    if (!_visualizerEnabledController.isClosed) {
      _visualizerEnabledController.add(enableActive);
    }
  }

  // --------------------------------------------------------------------------
  // Core Queue & Transport Implementations (Serialized)
  // --------------------------------------------------------------------------

  /// Internal implementation of [EngineAction.openQueue].
  Future<void> openQueueInternal(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) =>
      _serialize(() async {
        await _settleActiveTransition();
        _queueManager.setQueue(items, startIndex: startIndex, shuffle: shuffle);

        final current = _queueManager.currentItem;
        if (current == null) {
          await _resetDeckToStandby(_activePlayer);
          await _resetDeckToStandby(_standbyPlayer);
          _bumpEpoch();
          _setPhase(EnginePhase.idle);
          _emitQueueAndCursorState();
          return;
        }

        await _loadOrTransitionToTarget(
          current,
          play: false,
          isManual: true,
          forceHardLoad: true,
        );
      });

  /// Internal implementation of [EngineAction.play].
  Future<void> playInternal() => _serialize(() async {
        if (_queueManager.isEmpty) return;

        if (_phase == EnginePhase.autoCrossfading ||
            _phase == EnginePhase.manualCrossfading) {
          if (_crossfade.isPaused) {
            try {
              await Future.wait([
                _activePlayer.action.play(),
                _standbyPlayer.action.play(),
              ]);
            } catch (_) {}
            _crossfade.resume();
            _emitDerivedTransportState();
          }
          return;
        }

        if (_phase == EnginePhase.completed) {
          final target =
              _queueManager.jumpTo(0) ?? _queueManager.currentItem;
          if (target == null) return;
          await _loadOrTransitionToTarget(
            target,
            play: true,
            isManual: true,
            forceHardLoad: true,
          );
          return;
        }

        if (_phase == EnginePhase.idle) {
          final target = _queueManager.currentItem;
          if (target == null) return;
          await _loadOrTransitionToTarget(
            target,
            play: true,
            isManual: true,
            forceHardLoad: true,
          );
          return;
        }

        await _activePlayer.action.play();
        _setPhase(EnginePhase.playing);
      });

  /// Internal implementation of [EngineAction.pause].
  Future<void> pauseInternal() => _serialize(() async {
        if (_phase == EnginePhase.autoCrossfading ||
            _phase == EnginePhase.manualCrossfading) {
          _crossfade.pause();
          try {
            await Future.wait([
              _activePlayer.action.pause(),
              _standbyPlayer.action.pause(),
            ]);
          } catch (_) {}
          _emitDerivedTransportState();
          return;
        }

        if (_phase == EnginePhase.playing || _activePlayer.state.playing) {
          await _activePlayer.action.pause();
          _setPhase(EnginePhase.paused);
        }
      });

  /// Internal implementation of [EngineAction.togglePlayPause].
  Future<void> togglePlayPauseInternal() => _serialize(() async {
        if (state.playing) {
          if (_phase == EnginePhase.autoCrossfading ||
              _phase == EnginePhase.manualCrossfading) {
            _crossfade.pause();
            await Future.wait([
              _activePlayer.action.pause(),
              _standbyPlayer.action.pause(),
            ]);
            _emitDerivedTransportState();
          } else {
            await _activePlayer.action.pause();
            _setPhase(EnginePhase.paused);
          }
        } else {
          if (_phase == EnginePhase.autoCrossfading ||
              _phase == EnginePhase.manualCrossfading) {
            await Future.wait([
              _activePlayer.action.play(),
              _standbyPlayer.action.play(),
            ]);
            _crossfade.resume();
            _emitDerivedTransportState();
          } else if (_phase == EnginePhase.completed) {
            final target =
                _queueManager.jumpTo(0) ?? _queueManager.currentItem;
            if (target != null) {
              await _loadOrTransitionToTarget(
                target,
                play: true,
                isManual: true,
                forceHardLoad: true,
              );
            }
          } else if (_queueManager.currentItem != null) {
            await _activePlayer.action.play();
            _setPhase(EnginePhase.playing);
          }
        }
      });

  /// Internal implementation of [EngineAction.stop].
  Future<void> stopInternal() => _serialize(() async {
        _crossfade.cancel();
        _autoTarget = null;
        _bumpEpoch();
        await Future.wait([
          _resetDeckToStandby(_activePlayer),
          _resetDeckToStandby(_standbyPlayer),
        ]);
        _setPhase(EnginePhase.idle);
        _emitQueueAndCursorState();
      });

  /// Internal implementation of [EngineAction.seek].
  Future<void> seekInternal(Duration position) => _serialize(() async {
        if (_queueManager.isEmpty || _resolveIsLiveStream()) return;

        await _settleActiveTransition();

        if (_phase == EnginePhase.completed) {
          _setPhase(EnginePhase.paused);
        }

        final duration = _activePlayer.state.duration;
        final clamped = duration > Duration.zero
            ? Duration(
                milliseconds:
                    position.inMilliseconds.clamp(0, duration.inMilliseconds),
              )
            : (position < Duration.zero ? Duration.zero : position);

        await _activePlayer.action.seek(clamped);
        if (!_positionController.isClosed) {
          _positionController.add(clamped);
        }
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(clamped);
      });

  /// Internal implementation of [EngineAction.next].
  Future<void> nextInternal() => _serialize(() async {
        if (_queueManager.isEmpty) return;

        // If an automatic crossfade is already running, promote it in-place
        // into a committed manual crossfade without reopening the incoming deck!
        if (_promoteAutoToManual()) {
          return;
        }

        final shouldPlay = _phase == EnginePhase.completed || state.playing;
        await _settleActiveTransition();

        final nextItem = await _queueManager.next(isManual: true);
        if (nextItem == null) {
          await _enterEndOfQueue();
          return;
        }

        await _loadOrTransitionToTarget(
          nextItem,
          play: shouldPlay,
          isManual: true,
        );
      });

  /// Internal implementation of [EngineAction.previous].
  Future<void> previousInternal() => _serialize(() async {
        if (_queueManager.isEmpty) return;

        final shouldPlay = _phase == EnginePhase.completed || state.playing;

        // Settle any in-flight transition first:
        // - If autoCrossfading (queue still on outgoing track), reverts to outgoing.
        // - If manualCrossfading (queue already on incoming track), finalizes incoming.
        await _settleActiveTransition();

        final prevItem = _queueManager.previous(
          position: _activePlayer.state.position,
          isLiveStream: _resolveIsLiveStream(),
        );

        if (prevItem == null) {
          await _restartCurrentTrack(play: shouldPlay);
          return;
        }

        await _loadOrTransitionToTarget(
          prevItem,
          play: shouldPlay,
          isManual: true,
        );
      });

  /// Internal implementation of [EngineAction.skipToIndex].
  Future<void> skipToIndexInternal(int index) => _serialize(() async {
        if (index < 0 || index >= _queueManager.length) return;
        final shouldPlay = _phase == EnginePhase.completed || state.playing;
        await _settleActiveTransition();

        final item = _queueManager.jumpTo(index);
        if (item == null) return;

        await _loadOrTransitionToTarget(
          item,
          play: shouldPlay,
          isManual: true,
        );
      });

  /// Internal implementation of [EngineAction.insertNext].
  Future<void> insertNextInternal(EngineItem<T> item) => _serialize(() async {
        final wasEmpty = _queueManager.isEmpty;
        _queueManager.insertNext(item);

        if (wasEmpty && _queueManager.currentItem != null) {
          await _loadOrTransitionToTarget(
            _queueManager.currentItem!,
            play: false,
            isManual: true,
            forceHardLoad: true,
          );
          return;
        }

        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.append].
  Future<void> appendInternal(List<EngineItem<T>> items) =>
      _serialize(() async {
        if (items.isEmpty) return;
        final wasEmpty = _queueManager.isEmpty;
        _queueManager.append(items);

        if (wasEmpty && _queueManager.currentItem != null) {
          await _loadOrTransitionToTarget(
            _queueManager.currentItem!,
            play: false,
            isManual: true,
            forceHardLoad: true,
          );
          return;
        }

        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.removeAt].
  Future<void> removeAtInternal(int index) => _serialize(() async {
        if (index < 0 || index >= _queueManager.length) return;
        final wasPlaying = state.playing;
        final result = _queueManager.remove(index);
        if (result.removed == null) return;

        if (_queueManager.isEmpty) {
          await _settleActiveTransition();
          await _resetDeckToStandby(_activePlayer);
          await _resetDeckToStandby(_standbyPlayer);
          _bumpEpoch();
          _setPhase(EnginePhase.idle);
          _emitQueueAndCursorState();
          return;
        }

        if (result.wasCurrent) {
          await _settleActiveTransition();
          final nextCurrent = _queueManager.currentItem;
          if (nextCurrent != null) {
            await _loadOrTransitionToTarget(
              nextCurrent,
              play: wasPlaying,
              isManual: true,
            );
          }
          return;
        }

        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.reorder].
  Future<void> reorderInternal(int from, int to) => _serialize(() async {
        _queueManager.reorder(from, to);
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.clearQueue].
  Future<void> clearQueueInternal({bool keepCurrent = true}) =>
      _serialize(() async {
        await _settleActiveTransition();
        final shouldKeep = keepCurrent &&
            !_queueManager.isEmpty &&
            _phase != EnginePhase.idle &&
            _phase != EnginePhase.completed &&
            _phase != EnginePhase.error;

        _queueManager.clear(keepCurrent: shouldKeep);

        if (_queueManager.isEmpty) {
          await _resetDeckToStandby(_activePlayer);
          await _resetDeckToStandby(_standbyPlayer);
          _bumpEpoch();
          _setPhase(EnginePhase.idle);
        }

        _emitQueueAndCursorState();
      });

  // --------------------------------------------------------------------------
  // Shuffle, Loop, Crossfade, ReplayGain & Infinite Mix Implementations
  // --------------------------------------------------------------------------

  /// Internal implementation of [EngineAction.setShuffle].
  Future<void> setShuffleInternal(bool enabled) => _serialize(() async {
        _queueManager.setShuffle(enabled);
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.toggleShuffle].
  Future<bool> toggleShuffleInternal() => _serialize(() async {
        final res = _queueManager.toggleShuffle();
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
        return res;
      });

  /// Internal implementation of [EngineAction.setLoopMode].
  Future<void> setLoopModeInternal(LoopMode mode) => _serialize(() async {
        _queueManager.setLoopMode(mode);
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  /// Internal implementation of [EngineAction.cycleLoopMode].
  Future<LoopMode> cycleLoopModeInternal() => _serialize(() async {
        final nextMode = _queueManager.cycleLoopMode();
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
        return nextMode;
      });

  /// Internal implementation of [EngineAction.setCrossfadeConfig].
  Future<void> setCrossfadeConfigInternal(CrossfadeConfig config) =>
      _serialize(() async {
        if (_crossfadeConfig == config) return;
        _crossfadeConfig = config;
        if (!_crossfadeConfigController.isClosed) {
          _crossfadeConfigController.add(config);
        }
        if (!config.isEnabled && _phase == EnginePhase.autoCrossfading) {
          await _settleActiveTransition();
        } else {
          _maybeScheduleAutoCrossfade(_activePlayer.state.position);
        }
      });

  /// Internal implementation of [EngineAction.setVolumeNormalization].
  Future<void> setVolumeNormalizationInternal(bool enabled) =>
      _serialize(() async {
        if (_volumeNormalization == enabled) return;
        _volumeNormalization = enabled;
        await _applyItemReplayGain(_activePlayer, _queueManager.currentItem);
        if (!_volumeNormalizationController.isClosed) {
          _volumeNormalizationController.add(enabled);
        }
      });

  /// Internal implementation of [EngineAction.setInfiniteMix].
  Future<void> setInfiniteMixInternal(bool enabled) => _serialize(() async {
        if (_queueManager.infiniteMixEnabled == enabled) return;
        _queueManager.setInfiniteMix(enabled);
        if (!_infiniteMixController.isClosed) {
          _infiniteMixController.add(enabled);
        }
        _emitQueueAndCursorState();
        _maybeScheduleAutoCrossfade(_activePlayer.state.position);
      });

  // --------------------------------------------------------------------------
  // Volume, Speed, Pitch, Device & Studio DSP Implementations
  // --------------------------------------------------------------------------

  /// Internal implementation of [EngineAction.setVolume].
  Future<void> setVolumeInternal(double volume) => _serialize(() async {
        if (volume.isNaN || volume.isInfinite || volume < 0.0) {
          throw ArgumentError.value(
            volume,
            'volume',
            'Volume must be finite and non-negative (0.0..2.0)',
          );
        }
        final clamped = volume.clamp(0.0, 2.0);
        _masterVolume = clamped;

        if (_crossfade.isActive) {
          _crossfade.setMasterVolume(clamped);
        } else if (!_activePlayer.isDisposed) {
          await _activePlayer.action.setVolume(clamped);
        }

        if (!_volumeController.isClosed) {
          _volumeController.add(clamped);
        }
      });

  /// Internal implementation of [EngineAction.setRate].
  Future<void> setRateInternal(double rate) => _serialize(() async {
        final clamped = rate.clamp(0.1, 4.0);
        _playbackRate = clamped;
        _crossfade.setPlaybackRate(clamped);
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setRate(clamped),
          if (!_playerB.isDisposed) _playerB.action.setRate(clamped),
        ]);
        if (!_rateController.isClosed) {
          _rateController.add(clamped);
        }
      });

  /// Internal implementation of [EngineAction.setPitch].
  Future<void> setPitchInternal(double pitch) => _serialize(() async {
        final clamped = pitch.clamp(0.5, 2.0);
        _playbackPitch = clamped;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setPitch(clamped),
          if (!_playerB.isDisposed) _playerB.action.setPitch(clamped),
        ]);
        if (!_pitchController.isClosed) {
          _pitchController.add(clamped);
        }
      });

  /// Internal implementation of [EngineAction.setBufferSize].
  Future<void> setBufferSizeInternal(int bufferSize) => _serialize(() async {
        if (bufferSize < 0) {
          throw ArgumentError.value(
            bufferSize,
            'bufferSize',
            'Buffer size must be non-negative',
          );
        }
        _bufferSize = bufferSize;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setBufferSize(bufferSize),
          if (!_playerB.isDisposed) _playerB.action.setBufferSize(bufferSize),
        ]);
        if (!_bufferSizeController.isClosed) {
          _bufferSizeController.add(bufferSize);
        }
      });

  /// Internal implementation of [EngineAction.setEqualizer].
  Future<void> setEqualizerInternal(Equalizer equalizer) =>
      _serialize(() async {
        _equalizer = equalizer;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setEqualizer(equalizer),
          if (!_playerB.isDisposed) _playerB.action.setEqualizer(equalizer),
        ]);
        if (!_equalizerController.isClosed) {
          _equalizerController.add(equalizer);
        }
      });

  /// Internal implementation of [EngineAction.setDevice].
  Future<void> setDeviceInternal(AudioDevice device) => _serialize(() async {
        _audioDevice = device;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setDevice(device),
          if (!_playerB.isDisposed) _playerB.action.setDevice(device),
        ]);
        if (!_audioDeviceController.isClosed) {
          _audioDeviceController.add(_activePlayer.state.audioDevice);
        }
      });

  /// Internal implementation of [EngineAction.setSkipSilence].
  Future<void> setSkipSilenceInternal(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) =>
      _serialize(() async {
        final effectiveMode = enabled
            ? (mode == SilenceSkipMode.disabled
                ? SilenceSkipMode.continuous
                : mode)
            : SilenceSkipMode.disabled;
        final nextConfig = SilenceSkipConfig(
          mode: effectiveMode,
          thresholdDb: thresholdDb ?? _silenceConfig.thresholdDb,
          minSilenceDuration:
              minSilenceDuration ?? _silenceConfig.minSilenceDuration,
          padding: padding ?? _silenceConfig.padding,
        );
        await _applySilenceConfig(nextConfig);
      });

  /// Internal implementation of [EngineAction.setSilenceConfig].
  Future<void> setSilenceConfigInternal(SilenceSkipConfig config) =>
      _serialize(() async {
        await _applySilenceConfig(config);
      });

  Future<void> _applySilenceConfig(SilenceSkipConfig config) async {
    final wasEnabled = _silenceConfig.mode != SilenceSkipMode.disabled;
    final isEnabled = config.mode != SilenceSkipMode.disabled;
    _silenceConfig = config;
    await Future.wait([
      if (!_playerA.isDisposed) _playerA.action.setSilenceConfig(config),
      if (!_playerB.isDisposed) _playerB.action.setSilenceConfig(config),
    ]);
    if (wasEnabled != isEnabled && !_skipSilenceController.isClosed) {
      _skipSilenceController.add(isEnabled);
    }
    if (!_silenceConfigController.isClosed) {
      _silenceConfigController.add(config);
    }
  }

  /// Internal implementation of [EngineAction.setVisualizerEnabled] and
  /// [EngineAction.clearVisualizerOverride].
  Future<void> setVisualizerOverrideInternal(bool? override) async {
    ensureNotDisposed();
    _manualVisualizerOverride = override;
    _syncDeckVisualizerStates();
    await Future<void>.delayed(Duration.zero);
  }

  /// Internal implementation of [EngineAction.setReplayGain].
  Future<void> setReplayGainInternal({
    required double gainDb,
    double? peak,
    double preampDb = 0.0,
    bool preventClipping = true,
  }) =>
      _serialize(() async {
        if (!_activePlayer.isDisposed) {
          await _activePlayer.action.setReplayGain(
            gainDb: gainDb,
            peak: peak,
            preampDb: preampDb,
            preventClipping: preventClipping,
          );
        }
        if (!_replayGainController.isClosed) {
          _replayGainController.add(_activePlayer.state.replayGain);
        }
      });

  /// Internal implementation of [EngineAction.clearReplayGain].
  Future<void> clearReplayGainInternal() => _serialize(() async {
        if (!_activePlayer.isDisposed) {
          await _activePlayer.action.clearReplayGain();
        }
        if (!_replayGainController.isClosed) {
          _replayGainController.add(_activePlayer.state.replayGain);
        }
      });

  /// Internal implementation of [EngineAction.setPreamp].
  Future<void> setPreampInternal(double preampDb) => _serialize(() async {
        final clamped = preampDb.clamp(-12.0, 12.0);
        _preampDb = clamped;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setPreamp(clamped),
          if (!_playerB.isDisposed) _playerB.action.setPreamp(clamped),
        ]);
        if (_volumeNormalization) {
          await _applyItemReplayGain(_activePlayer, _queueManager.currentItem);
        }
        if (!_preampController.isClosed) {
          _preampController.add(clamped);
        }
      });

  /// Internal implementation of [EngineAction.setBalance].
  Future<void> setBalanceInternal(double pan) => _serialize(() async {
        final clamped = pan.clamp(-1.0, 1.0);
        _balance = clamped;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setBalance(clamped),
          if (!_playerB.isDisposed) _playerB.action.setBalance(clamped),
        ]);
        if (!_balanceController.isClosed) {
          _balanceController.add(clamped);
        }
      });

  /// Internal implementation of [EngineAction.setMono].
  Future<void> setMonoInternal(bool enabled) => _serialize(() async {
        _mono = enabled;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setMono(enabled),
          if (!_playerB.isDisposed) _playerB.action.setMono(enabled),
        ]);
        if (!_monoController.isClosed) {
          _monoController.add(enabled);
        }
      });

  /// Internal implementation of [EngineAction.setCrossfeed].
  Future<void> setCrossfeedInternal(CrossfeedMode mode) =>
      _serialize(() async {
        _crossfeed = mode;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setCrossfeed(mode),
          if (!_playerB.isDisposed) _playerB.action.setCrossfeed(mode),
        ]);
        if (!_crossfeedController.isClosed) {
          _crossfeedController.add(mode);
        }
      });

  /// Internal implementation of [EngineAction.setSpatializer].
  Future<void> setSpatializerInternal({
    required bool enabled,
    double width = 1.3,
  }) =>
      _serialize(() async {
        final clampedWidth = width.clamp(1.0, 2.0);
        _spatializerEnabled = enabled;
        _spatializerWidth = clampedWidth;
        await Future.wait([
          if (!_playerA.isDisposed)
            _playerA.action.setSpatializer(
              enabled: enabled,
              width: clampedWidth,
            ),
          if (!_playerB.isDisposed)
            _playerB.action.setSpatializer(
              enabled: enabled,
              width: clampedWidth,
            ),
        ]);
        if (!_spatializerEnabledController.isClosed) {
          _spatializerEnabledController.add(enabled);
        }
        if (!_spatializerWidthController.isClosed) {
          _spatializerWidthController.add(clampedWidth);
        }
      });

  /// Internal implementation of [EngineAction.setLimiter].
  Future<void> setLimiterInternal(bool enabled) => _serialize(() async {
        _limiterEnabled = enabled;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setLimiter(enabled),
          if (!_playerB.isDisposed) _playerB.action.setLimiter(enabled),
        ]);
        if (!_limiterEnabledController.isClosed) {
          _limiterEnabledController.add(enabled);
        }
      });

  /// Internal implementation of [EngineAction.setReverb].
  Future<void> setReverbInternal(Reverb config) => _serialize(() async {
        _reverb = config;
        await Future.wait([
          if (!_playerA.isDisposed) _playerA.action.setReverb(config),
          if (!_playerB.isDisposed) _playerB.action.setReverb(config),
        ]);
        if (!_reverbController.isClosed) {
          _reverbController.add(config);
        }
      });

  // --------------------------------------------------------------------------
  // Deck Preparation, Hard Load, Manual & Automatic Crossfades
  // --------------------------------------------------------------------------

  /// Loads [item] or transitions to it from the current deck, automatically
  /// skipping unplayable items up to the queue length.
  Future<void> _loadOrTransitionToTarget(
    EngineItem<T> item, {
    required bool play,
    required bool isManual,
    bool forceHardLoad = false,
  }) async {
    final useCrossfade = !forceHardLoad &&
        play &&
        _activePlayer.state.playing &&
        _phase != EnginePhase.idle &&
        _phase != EnginePhase.completed &&
        _phase != EnginePhase.error;

    var candidate = item;
    final maxAttempts = math.max(1, _queueManager.length);
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final ok = useCrossfade
          ? await _startManualCrossfade(
              candidate,
              targetDuration: isManual
                  ? _crossfadeConfig.manualDuration
                  : Duration.zero,
            )
          : await _hardLoad(candidate, play: play);
      if (ok) return;

      final nextCandidate = await _queueManager.next(isManual: isManual);
      if (nextCandidate == null ||
          InternalQueueManager.isSameItem(nextCandidate, candidate)) {
        break;
      }
      candidate = nextCandidate;
    }

    await _resetDeckToStandby(_activePlayer);
    await _resetDeckToStandby(_standbyPlayer);
    _setPhase(EnginePhase.error);
    _emitQueueAndCursorState();
  }

  /// Prepares [item] directly on `_activePlayer` (stopping `_standbyPlayer`).
  Future<bool> _hardLoad(EngineItem<T> item, {required bool play}) async {
    _bumpEpoch();
    _setPhase(EnginePhase.loading);
    _emitQueueAndCursorState();

    await _resetDeckToStandby(_standbyPlayer);
    final ok = await _prepareDeck(
      _activePlayer,
      item,
      initialVolume: _masterVolume,
    );

    if (!ok) {
      return false;
    }

    if (play) {
      try {
        await _activePlayer.action.play();
      } catch (_) {
        await _resetDeckToStandby(_activePlayer);
        return false;
      }
    }

    _setPhase(play ? EnginePhase.playing : EnginePhase.paused);
    _emitQueueAndCursorState();
    _emitActiveDeckSnapshot();
    return true;
  }

  /// Opens [item] on `_standbyPlayer` at `0.0` volume, swaps deck roles, and
  /// ramps volumes over [targetDuration].
  Future<bool> _startManualCrossfade(
    EngineItem<T> item, {
    required Duration targetDuration,
  }) async {
    final outgoing = _activePlayer;
    final incoming = _standbyPlayer;

    // Guarantee standby deck is 100% stopped and clean before opening
    await _resetDeckToStandby(incoming);

    final ok = await _prepareDeck(
      incoming,
      item,
      initialVolume: 0.0,
    );
    if (!ok) {
      await _resetDeckToStandby(incoming);
      return false;
    }

    final outgoingRemaining =
        outgoing.state.duration > Duration.zero
            ? outgoing.state.duration - outgoing.state.position
            : Duration.zero;
    final clampedDuration = _clampCrossfadeDuration(
      outgoingDuration: outgoing.state.duration,
      outgoingRemaining: outgoingRemaining,
      targetDuration: targetDuration,
      incomingDuration: incoming.state.duration,
      isOutgoingLive: _resolveIsLiveStream(),
      isIncomingLive: item.isLiveStream ||
          (incoming.state.trackMetadata?.isLiveStream ?? false),
    );

    // Swap active and standby roles BEFORE starting playback on incoming so
    // telemetry and state immediately reflect the new active track.
    _swapDecks();
    final transitionEpoch = _epoch;

    try {
      await incoming.action.play();
    } catch (_) {
      return false;
    }

    if (clampedDuration.inMilliseconds <=
        InternalCrossfadeController.immediateCutThresholdMs) {
      await _resetDeckToStandby(outgoing);
      await incoming.action.setVolume(_masterVolume);
      _setPhase(EnginePhase.playing);
      _emitQueueAndCursorState();
      _emitActiveDeckSnapshot();
      return true;
    }

    _setPhase(EnginePhase.manualCrossfading);
    _emitQueueAndCursorState();
    _emitActiveDeckSnapshot();

    await _crossfade.start(
      playerOut: outgoing,
      playerIn: incoming,
      duration: clampedDuration,
      curve: _crossfadeConfig.curve,
      masterVolume: _masterVolume,
      playbackRate: _playbackRate,
      onComplete: () => _onCrossfadeComplete(transitionEpoch),
    );
    return true;
  }

  /// Restarts the currently loaded track at `0:00` without reopening the file.
  Future<void> _restartCurrentTrack({required bool play}) async {
    await _settleActiveTransition();
    await _resetDeckToStandby(_standbyPlayer);
    _bumpEpoch();

    if (!_resolveIsLiveStream()) {
      await _activePlayer.action.seek(Duration.zero);
    }
    await _activePlayer.action.setVolume(_masterVolume);

    if (play) {
      await _activePlayer.action.play();
      _setPhase(EnginePhase.playing);
    } else {
      await _activePlayer.action.pause();
      _setPhase(EnginePhase.paused);
    }

    _emitQueueAndCursorState();
    _emitActiveDeckSnapshot();
  }

  Future<void> _enterEndOfQueue() async {
    await _settleActiveTransition();
    await _resetDeckToStandby(_standbyPlayer);
    try {
      await _activePlayer.action.pause();
    } catch (_) {}
    _setPhase(EnginePhase.completed);
    _emitQueueAndCursorState();
  }

  Future<void> _advanceAfterNaturalCompletion() async {
    final before = _queueManager.currentItem;
    final target = await _queueManager.next(isManual: false);

    if (target == null) {
      await _enterEndOfQueue();
    } else if (InternalQueueManager.isSameItem(target, before)) {
      await _restartCurrentTrack(play: true);
    } else {
      await _loadOrTransitionToTarget(
        target,
        play: true,
        isManual: false,
      );
    }
  }

  // --------------------------------------------------------------------------
  // Automatic End-of-Track Crossfade Planning, Promotion & Invalidations
  // --------------------------------------------------------------------------

  ({EngineItem<T> next, Duration duration})? _planAutoCrossfade(
    Duration position,
  ) {
    if (!_crossfadeConfig.isEnabled) return null;
    if (_phase != EnginePhase.playing || !_activePlayer.state.playing) {
      return null;
    }
    if (_resolveIsLiveStream()) return null;

    final total = _activePlayer.state.duration;
    if (total <= Duration.zero) return null;
    final remaining = total - position;
    if (remaining <= Duration.zero) return null;

    final next = _queueManager.peekNext(distinct: true);
    if (next == null ||
        InternalQueueManager.isSameItem(next, _failedAutoTarget)) {
      return null;
    }

    final plannedDuration = _clampCrossfadeDuration(
      outgoingDuration: total,
      outgoingRemaining: remaining,
      targetDuration: _crossfadeConfig.duration,
      incomingDuration: Duration.zero,
      isOutgoingLive: false,
      isIncomingLive: next.isLiveStream,
    );
    if (plannedDuration <= Duration.zero || remaining > plannedDuration) {
      return null;
    }
    return (next: next, duration: plannedDuration);
  }

  void _maybeScheduleAutoCrossfade(Duration position) {
    if (isDisposed ||
        _autoStartScheduled ||
        _phase == EnginePhase.autoCrossfading ||
        _phase == EnginePhase.manualCrossfading) {
      return;
    }
    if (_planAutoCrossfade(position) == null) return;

    _autoStartScheduled = true;
    _scheduleInternal(() async {
      _autoStartScheduled = false;
      if (_phase != EnginePhase.playing) return;
      final plan = _planAutoCrossfade(_activePlayer.state.position);
      if (plan == null) return;
      await _startAutoCrossfade(plan.next, plan.duration);
    });
  }

  Future<void> _startAutoCrossfade(
    EngineItem<T> next,
    Duration plannedDuration,
  ) async {
    final outgoing = _activePlayer;
    final incoming = _standbyPlayer;
    final startEpoch = _epoch;
    _autoTarget = next;

    await _resetDeckToStandby(incoming);
    final ok = await _prepareDeck(
      incoming,
      next,
      initialVolume: 0.0,
    );

    if (isDisposed ||
        _epoch != startEpoch ||
        !InternalQueueManager.isSameItem(_autoTarget, next)) {
      await _resetDeckToStandby(incoming);
      return;
    }

    if (!ok) {
      _autoTarget = null;
      _failedAutoTarget = next;
      await _resetDeckToStandby(incoming);
      return;
    }

    // Re-clamp using actual remaining time on outgoing and resolved duration
    // on incoming (now known natively by MiniaudioPlayer after _prepareDeck!).
    final remaining = outgoing.state.duration - outgoing.state.position;
    final effectiveDuration = _clampCrossfadeDuration(
      outgoingDuration: outgoing.state.duration,
      outgoingRemaining: remaining <= Duration.zero ? Duration.zero : remaining,
      targetDuration: plannedDuration,
      incomingDuration: incoming.state.duration,
      isOutgoingLive: false,
      isIncomingLive: next.isLiveStream ||
          (incoming.state.trackMetadata?.isLiveStream ?? false),
    );

    try {
      await incoming.action.play();
    } catch (_) {
      _autoTarget = null;
      _failedAutoTarget = next;
      await _resetDeckToStandby(incoming);
      return;
    }

    _setPhase(EnginePhase.autoCrossfading);

    await _crossfade.start(
      playerOut: outgoing,
      playerIn: incoming,
      duration: effectiveDuration,
      curve: _crossfadeConfig.curve,
      masterVolume: _masterVolume,
      playbackRate: _playbackRate,
      onComplete: () => _onCrossfadeComplete(startEpoch),
    );
  }

  /// Promotes an active `autoCrossfading` transition into a committed
  /// `manualCrossfading` transition when the user calls `next()`.
  bool _promoteAutoToManual() {
    if (_phase != EnginePhase.autoCrossfading || !_crossfade.isActive) {
      return false;
    }
    final target = _autoTarget;
    if (target == null) return false;

    // Transition to manualCrossfading BEFORE committing on the queue so the
    // synchronous nextItemStream emission does not abort the fade.
    _phase = EnginePhase.manualCrossfading;
    if (_queueManager.commitNext(target) == null) {
      _phase = EnginePhase.autoCrossfading;
      return false;
    }

    _autoTarget = null;
    _swapDecks();
    _setPhase(EnginePhase.manualCrossfading);
    final promotedEpoch = _epoch;
    _crossfade.updateOnComplete(() => _onCrossfadeComplete(promotedEpoch));
    _crossfade.capRemainingDuration(_crossfadeConfig.manualDuration);
    _emitQueueAndCursorState();
    _emitActiveDeckSnapshot();
    return true;
  }

  void _onCrossfadeComplete(int originEpoch) {
    if (isDisposed) return;
    _scheduleInternal(() async {
      if (isDisposed) return;

      if (_phase == EnginePhase.autoCrossfading && _epoch == originEpoch) {
        final target = _autoTarget;
        _autoTarget = null;
        if (target == null || _queueManager.commitNext(target) == null) {
          await _resetDeckToStandby(_standbyPlayer);
          _setPhase(EnginePhase.playing);
          _scheduleCompletion(verifyPosition: false);
          _emitQueueAndCursorState();
          return;
        }
        _swapDecks();
      } else if (_phase != EnginePhase.manualCrossfading ||
          _epoch != originEpoch) {
        return;
      }

      await _resetDeckToStandby(_standbyPlayer);
      if (!_activePlayer.isDisposed) {
        await _activePlayer.action.setVolume(_masterVolume);
      }

      _setPhase(
        _activePlayer.state.playing ? EnginePhase.playing : EnginePhase.paused,
      );
      _emitQueueAndCursorState();
      _emitActiveDeckSnapshot();

      if (_activePlayer.state.completed) {
        _scheduleCompletion(verifyPosition: false);
      }
    });
  }

  void _onNextCandidateChanged(EngineItem<T>? candidate) {
    if (_phase != EnginePhase.autoCrossfading && _autoTarget == null) return;
    if (InternalQueueManager.isSameItem(candidate, _autoTarget)) return;
    _scheduleInternal(() async {
      if (_phase == EnginePhase.autoCrossfading || _autoTarget != null) {
        await _settleActiveTransition();
      }
    });
  }

  void _onBackgroundQueueMutated() {
    if (isDisposed || _phase == EnginePhase.loading) return;
    _emitQueueAndCursorState();
    _maybeScheduleAutoCrossfade(_activePlayer.state.position);
  }

  Duration _clampCrossfadeDuration({
    required Duration outgoingDuration,
    required Duration outgoingRemaining,
    required Duration targetDuration,
    required Duration incomingDuration,
    required bool isOutgoingLive,
    required bool isIncomingLive,
  }) {
    if (targetDuration <= Duration.zero) return Duration.zero;
    if (!isOutgoingLive &&
        outgoingDuration > Duration.zero &&
        outgoingRemaining <= Duration.zero) {
      return Duration.zero;
    }

    var dur = targetDuration;
    if (!isOutgoingLive &&
        outgoingRemaining > Duration.zero &&
        outgoingRemaining < dur) {
      dur = outgoingRemaining;
    }
    if (!isOutgoingLive && outgoingDuration > Duration.zero) {
      final halfOutgoing = Duration(
        milliseconds: outgoingDuration.inMilliseconds ~/ 2,
      );
      if (halfOutgoing > Duration.zero && dur > halfOutgoing) {
        dur = halfOutgoing;
      }
    }
    if (!isIncomingLive && incomingDuration > Duration.zero) {
      final halfIncoming = Duration(
        milliseconds: incomingDuration.inMilliseconds ~/ 2,
      );
      if (halfIncoming > Duration.zero && dur > halfIncoming) {
        dur = halfIncoming;
      }
    }
    return dur;
  }

  // --------------------------------------------------------------------------
  // Natural Track Completion Handling
  // --------------------------------------------------------------------------

  void _scheduleCompletion({bool verifyPosition = true}) {
    if (_phase == EnginePhase.completed || _phase == EnginePhase.idle) return;
    if (_scheduledCompletionEpoch == _epoch) return;
    _scheduledCompletionEpoch = _epoch;
    final capturedEpoch = _epoch;
    final capturedDeck = _activePlayer;

    _scheduleInternal(() async {
      if (_phase == EnginePhase.completed || _phase == EnginePhase.idle) return;
      if (capturedEpoch != _epoch || !identical(capturedDeck, _activePlayer)) {
        return;
      }
      if (_phase == EnginePhase.autoCrossfading) return;
      if (verifyPosition && !_isDeckAtEnd(capturedDeck)) {
        _scheduledCompletionEpoch = null;
        return;
      }
      await _advanceAfterNaturalCompletion();
    });
  }

  bool _isDeckAtEnd(MiniaudioPlayer deck) {
    if (deck.state.completed) return true;
    final total = deck.state.duration;
    if (total <= Duration.zero) return true;
    return deck.state.position >= total - _completionTolerance;
  }

  // --------------------------------------------------------------------------
  // Low-Level Deck Preparation & DSP Sync
  // --------------------------------------------------------------------------

  /// Prepares [item] on [deck] at [initialVolume] without starting playback
  /// and without any redundant `seek(Duration.zero)` calls (since
  /// `deck.action.open` natively initializes the C decoder at frame `0`).
  Future<bool> _prepareDeck(
    MiniaudioPlayer deck,
    EngineItem<T> item, {
    required double initialVolume,
  }) async {
    if (deck.isDisposed || !item.hasValidSource) return false;
    try {
      await deck.action.setVolume(initialVolume.clamp(0.0, 2.0));
      await _configureDeckDsp(deck);
      await _applyItemReplayGain(deck, item);
      await deck.action.open(item.source);
      return true;
    } catch (_) {
      await _resetDeckToStandby(deck);
      return false;
    }
  }

  Future<void> _configureDeckDsp(MiniaudioPlayer deck) async {
    try {
      await Future.wait([
        deck.action.setRate(_playbackRate),
        deck.action.setPitch(_playbackPitch),
        deck.action.setEqualizer(_equalizer),
        deck.action.setReverb(_reverb),
        deck.action.setSilenceConfig(_silenceConfig),
        deck.action.setPreamp(_preampDb),
        deck.action.setBalance(_balance),
        deck.action.setMono(_mono),
        deck.action.setCrossfeed(_crossfeed),
        deck.action.setSpatializer(
          enabled: _spatializerEnabled,
          width: _spatializerWidth,
        ),
        deck.action.setLimiter(_limiterEnabled),
        if (_bufferSize > 0) deck.action.setBufferSize(_bufferSize),
        if (!_audioDevice.isAuto && _audioDevice.id.isNotEmpty)
          deck.action.setDevice(_audioDevice),
      ]);
    } catch (_) {}
  }

  Future<void> _applyItemReplayGain(
    MiniaudioPlayer deck,
    EngineItem<T>? item,
  ) async {
    if (deck.isDisposed) return;
    try {
      if (_volumeNormalization &&
          item != null &&
          (item.replayGainDb != null || item.replayPeak != null)) {
        await deck.action.setReplayGain(
          gainDb: item.replayGainDb ?? 0.0,
          peak: item.replayPeak,
          preampDb: _preampDb,
          preventClipping: true,
        );
      } else {
        await deck.action.clearReplayGain();
      }
    } catch (_) {}
  }

  // --------------------------------------------------------------------------
  // Reactive Stream Multiplexing from Active Deck
  // --------------------------------------------------------------------------

  void _unbindActiveDeck() {
    for (final sub in _activeDeckSubscriptions) {
      sub.cancel();
    }
    _activeDeckSubscriptions.clear();
  }

  void _bindActiveDeck() {
    _unbindActiveDeck();
    if (isDisposed) return;

    final deck = _activePlayer;
    bool isCurrent() => !isDisposed && identical(deck, _activePlayer);

    _activeDeckSubscriptions.add(
      deck.stream.position.listen((pos) {
        if (!isCurrent() || _phase == EnginePhase.completed) return;
        if (!_positionController.isClosed) {
          _positionController.add(pos);
        }
        _emitHasPreviousIfNeeded();
        _maybeScheduleAutoCrossfade(pos);
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.duration.listen((dur) {
        if (!isCurrent()) return;
        if (_lastEmittedDuration != dur) {
          _lastEmittedDuration = dur;
          if (!_durationController.isClosed) {
            _durationController.add(dur);
          }
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.playing.listen((playing) {
        if (!isCurrent()) return;
        if (_phase == EnginePhase.playing && !playing && !deck.state.completed) {
          _setPhase(EnginePhase.paused);
        } else if (_phase == EnginePhase.paused && playing) {
          _setPhase(EnginePhase.playing);
        } else {
          _emitDerivedTransportState();
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.buffering.listen((buffering) {
        if (!isCurrent()) return;
        if (_lastEmittedBuffering != buffering) {
          _lastEmittedBuffering = buffering;
          if (!_bufferingController.isClosed) {
            _bufferingController.add(buffering);
          }
        }
        _emitDerivedTransportState();
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.opening.listen((opening) {
        if (!isCurrent()) return;
        _emitDerivedTransportState();
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.completed.listen((completed) {
        if (!isCurrent() || _phase == EnginePhase.completed) return;
        if (!completed) return;
        if (_phase == EnginePhase.autoCrossfading) return;
        _scheduleCompletion();
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.bufferedPosition.listen((pos) {
        if (!isCurrent()) return;
        if (!_bufferedPositionController.isClosed) {
          _bufferedPositionController.add(pos);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.bufferedPercentage.listen((pct) {
        if (!isCurrent()) return;
        if (!_bufferedPercentageController.isClosed) {
          _bufferedPercentageController.add(pct);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.bufferedRange.listen((range) {
        if (!isCurrent()) return;
        if (!_bufferedRangeController.isClosed) {
          _bufferedRangeController.add(range);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.trackMetadata.listen((meta) {
        if (!isCurrent()) return;
        if (!_trackMetadataController.isClosed) {
          _trackMetadataController.add(meta);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.audioBitrate.listen((br) {
        if (!isCurrent()) return;
        if (!_audioBitrateController.isClosed) {
          _audioBitrateController.add(br);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.silenceSavedDuration.listen((saved) {
        if (!isCurrent()) return;
        if (!_silenceSavedDurationController.isClosed) {
          _silenceSavedDurationController.add(saved);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.visualizer.listen((vis) {
        if (!isCurrent() || _phase == EnginePhase.completed) return;
        if (!_visualizerController.isClosed && _hasVisualizerListeners) {
          _visualizerController.add(vis);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.replayGain.listen((rg) {
        if (!isCurrent()) return;
        if (!_replayGainController.isClosed) {
          _replayGainController.add(rg);
        }
      }),
    );

    _activeDeckSubscriptions.add(
      deck.stream.metaBytes.listen((mb) {
        if (!isCurrent()) return;
        if (!_metaBytesController.isClosed) {
          _metaBytesController.add(mb);
        }
      }),
    );
  }

  void _emitDerivedTransportState() {
    if (isDisposed) return;

    final nowPlaying = _resolvePlaying();
    if (_lastEmittedPlaying != nowPlaying) {
      _lastEmittedPlaying = nowPlaying;
      if (!_playingController.isClosed) {
        _playingController.add(nowPlaying);
      }
    }

    final nowOpening = state.opening;
    if (_lastEmittedOpening != nowOpening) {
      _lastEmittedOpening = nowOpening;
      if (!_openingController.isClosed) {
        _openingController.add(nowOpening);
      }
    }

    final nowCompleted = _phase == EnginePhase.completed;
    if (_lastEmittedCompleted != nowCompleted) {
      _lastEmittedCompleted = nowCompleted;
      if (!_completedController.isClosed) {
        _completedController.add(nowCompleted);
      }
    }

    final nowPlaybackState = _resolvePlaybackState();
    if (_lastEmittedPlaybackState != nowPlaybackState) {
      _lastEmittedPlaybackState = nowPlaybackState;
      if (!_playbackStateController.isClosed) {
        _playbackStateController.add(nowPlaybackState);
      }
    }
  }

  void _emitActiveDeckSnapshot() {
    if (isDisposed) return;
    final deck = _activePlayer;

    final dur = deck.state.duration;
    if (_lastEmittedDuration != dur) {
      _lastEmittedDuration = dur;
      if (!_durationController.isClosed) {
        _durationController.add(dur);
      }
    }

    if (!_positionController.isClosed) {
      _positionController.add(_resolvePosition());
    }
    if (!_trackMetadataController.isClosed) {
      _trackMetadataController.add(deck.state.trackMetadata);
    }
    if (!_audioBitrateController.isClosed && deck.state.audioBitrate > 0) {
      _audioBitrateController.add(deck.state.audioBitrate);
    }
    if (!_replayGainController.isClosed) {
      _replayGainController.add(deck.state.replayGain);
    }
  }

  void _emitHasPreviousIfNeeded() {
    final hp = _resolveHasPrevious();
    if (_lastEmittedHasPrevious != hp) {
      _lastEmittedHasPrevious = hp;
      if (!_hasPreviousController.isClosed) {
        _hasPreviousController.add(hp);
      }
    }
  }

  void _emitQueueAndCursorState() {
    if (isDisposed) return;

    final currentQueue = _queueManager.activeQueue;
    if (!identical(_lastEmittedQueue, currentQueue)) {
      _lastEmittedQueue = currentQueue;
      if (!_queueController.isClosed) {
        _queueController.add(currentQueue);
      }
    }

    final idx = _queueManager.currentIndex;
    if (_lastEmittedIndex != idx) {
      _lastEmittedIndex = idx;
      if (!_currentIndexController.isClosed) {
        _currentIndexController.add(idx);
      }
    }

    final item = _queueManager.currentItem;
    if (!InternalQueueManager.isSameItem(_lastEmittedItem, item)) {
      _lastEmittedItem = item;
      if (!_currentItemController.isClosed) {
        _currentItemController.add(item);
      }
      if (!_currentDataController.isClosed) {
        _currentDataController.add(item?.data);
      }
    }

    final hn = _queueManager.hasNext;
    if (_lastEmittedHasNext != hn) {
      _lastEmittedHasNext = hn;
      if (!_hasNextController.isClosed) {
        _hasNextController.add(hn);
      }
    }

    _emitHasPreviousIfNeeded();

    final sh = _queueManager.isShuffled;
    if (_lastEmittedShuffle != sh) {
      _lastEmittedShuffle = sh;
      if (!_shuffleController.isClosed) {
        _shuffleController.add(sh);
      }
    }

    final lm = _queueManager.loopMode;
    if (_lastEmittedLoopMode != lm) {
      _lastEmittedLoopMode = lm;
      if (!_loopModeController.isClosed) {
        _loopModeController.add(lm);
      }
    }

    _emitDerivedTransportState();
  }

  // --------------------------------------------------------------------------
  // Teardown & Cleanup
  // --------------------------------------------------------------------------

  /// Disposes the engine, cancels any active crossfade, closes all broadcast
  /// streams, and destroys both underlying [MiniaudioPlayer] decks (if owned).
  Future<void> dispose() async {
    if (isDisposed) return;
    _phase = EnginePhase.disposed;
    _crossfade.dispose();
    _autoTarget = null;

    await _nextCandidateSubscription?.cancel();
    _nextCandidateSubscription = null;
    await _queueManager.dispose();

    _unbindActiveDeck();

    if (_ownsPlayers) {
      await _playerA.dispose();
      await _playerB.dispose();
    }

    await _phaseController.close();
    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _completedController.close();
    await _openingController.close();
    await _playbackStateController.close();
    await _bufferedPositionController.close();
    await _bufferedPercentageController.close();
    await _bufferedRangeController.close();
    await _trackMetadataController.close();
    await _volumeController.close();
    await _rateController.close();
    await _pitchController.close();
    await _bufferSizeController.close();
    await _audioBitrateController.close();
    await _equalizerController.close();
    await _audioDeviceController.close();
    await _skipSilenceController.close();
    await _silenceConfigController.close();
    await _silenceSavedDurationController.close();
    await _visualizerController.close();
    await _visualizerEnabledController.close();
    await _preampController.close();
    await _replayGainController.close();
    await _balanceController.close();
    await _monoController.close();
    await _crossfeedController.close();
    await _spatializerEnabledController.close();
    await _spatializerWidthController.close();
    await _reverbController.close();
    await _limiterEnabledController.close();
    await _queueController.close();
    await _currentIndexController.close();
    await _currentItemController.close();
    await _currentDataController.close();
    await _hasNextController.close();
    await _hasPreviousController.close();
    await _shuffleController.close();
    await _loopModeController.close();
    await _crossfadeConfigController.close();
    await _isCrossfadingController.close();
    await _volumeNormalizationController.close();
    await _infiniteMixController.close();
    await _metaBytesController.close();
  }
}
