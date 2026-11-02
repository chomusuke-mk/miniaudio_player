import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../platform/platform_select.dart';
import '../reverb.dart';
import '../rust/api/engine.dart' as rust_engine;
import '../rust/api/types.dart' as rust_types;
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_state.dart';
import 'engine_stream.dart';
import 'logger.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'need_more_tracks_event.dart';
import 'player_state.dart' show PlaybackState;
import 'recording.dart';
import 'silence_skip_config.dart';
import 'spatial.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

part 'engine_action.dart';

/// Encapsulates a synchronous engine state value paired with a broadcast [StreamController].
class _EngineProperty<V> {
  V value;
  final StreamController<V> controller;

  _EngineProperty(
    this.value, {
    void Function()? onListen,
    void Function()? onCancel,
  }) : controller = StreamController<V>.broadcast(
          onListen: onListen,
          onCancel: onCancel,
        );

  void emit(V nextValue) {
    value = nextValue;
    if (!controller.isClosed) {
      controller.add(nextValue);
    }
  }

  Future<void> close() => controller.close();
}

/// Decoupled dual-deck audio engine with unified queue management,
/// sample-accurate crossfade interpolation in Rust, and composite visualizer processing.
class MiniaudioEngine<T> {
  rust_engine.RustEngine? _rustEngine;
  StreamSubscription<rust_types.RustEngineEvent>? _eventSub;
  Future<void>? _initFuture;
  bool _isDisposed = false;

  /// Whether this engine instance has been disposed.
  bool get isDisposed => _isDisposed;

  final List<AudioSource<T>> _queue = [];
  final Map<int, AudioSource<T>> _shadowItems = {};
  int _nextAutoId = 0;

  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;

  // Private reactive state & stream properties
  final _phase = _EngineProperty<EnginePhase>(EnginePhase.idle);
  final _position = _EngineProperty<Duration>(Duration.zero);
  final _duration = _EngineProperty<Duration>(Duration.zero);
  final _playing = _EngineProperty<bool>(false);
  final _buffering = _EngineProperty<bool>(false);
  final _completed = _EngineProperty<bool>(false);
  final _opening = _EngineProperty<bool>(false);
  final _playbackState = _EngineProperty<PlaybackState>(PlaybackState.stopped);
  final _bufferedPosition = _EngineProperty<Duration>(Duration.zero);
  final _bufferedPercentage = _EngineProperty<double>(0.0);
  final _bufferedRange = _EngineProperty<BufferedRange>(const BufferedRange());
  final _trackMetadata = _EngineProperty<AudioTrackMetadata?>(null);
  final _volume = _EngineProperty<double>(1.0);
  final _rate = _EngineProperty<double>(1.0);
  final _pitch = _EngineProperty<double>(1.0);
  late final _EngineProperty<int> _bufferSize;
  final _audioBitrate = _EngineProperty<int>(0);
  final _equalizer = _EngineProperty<Equalizer>(Equalizer.flat);
  late final _EngineProperty<AudioDevice> _audioDevice;
  late final _EngineProperty<bool> _pauseOnDeviceChange;
  final _skipSilence = _EngineProperty<bool>(false);
  final _silenceConfig =
      _EngineProperty<SilenceSkipConfig>(const SilenceSkipConfig());
  final _silenceSavedDuration = _EngineProperty<Duration>(Duration.zero);
  late final _EngineProperty<VisualizerData> _visualizer;
  final _visualizerEnabled = _EngineProperty<bool>(false);
  final _preamp = _EngineProperty<double>(0.0);
  final _replayGain =
      _EngineProperty<ReplayGainConfig>(const ReplayGainConfig());
  final _balance = _EngineProperty<double>(0.0);
  final _mono = _EngineProperty<bool>(false);
  final _crossfeed = _EngineProperty<CrossfeedMode>(CrossfeedMode.off);
  final _spatializerEnabled = _EngineProperty<bool>(false);
  final _spatializerWidth = _EngineProperty<double>(1.0);
  final _reverb = _EngineProperty<Reverb>(Reverb.off);
  final _limiterEnabled = _EngineProperty<bool>(true);
  late final _EngineProperty<List<AudioSource<T>>> _queueProp;
  final _currentIndex = _EngineProperty<int>(-1);
  late final _EngineProperty<AudioSource<T>?> _currentItem;
  late final _EngineProperty<T?> _currentData;
  final _hasNext = _EngineProperty<bool>(false);
  final _hasPrevious = _EngineProperty<bool>(false);
  final _shuffle = _EngineProperty<bool>(false);
  final _loopMode = _EngineProperty<LoopMode>(LoopMode.off);
  late final _EngineProperty<CrossfadeConfig> _crossfadeConfig;
  final _isCrossfading = _EngineProperty<bool>(false);
  final _volumeNormalization = _EngineProperty<bool>(true);
  final _infiniteMix = _EngineProperty<bool>(false);
  final _defaultReplayGain = _EngineProperty<double>(0.0);
  final _forcedReplayGain = _EngineProperty<double?>(null);
  final _replayGainModeProp =
      _EngineProperty<ReplayGainMode>(ReplayGainMode.track);
  final _metaBytes = _EngineProperty<Uint8List?>(null);
  final _isRecording = _EngineProperty<bool>(false);
  final _isMicrophoneEnabled = _EngineProperty<bool>(false);
  final _micVolume = _EngineProperty<double>(1.0);
  final _cueConfig = _EngineProperty<CueConfig>(const CueConfig());
  final _duckingConfig = _EngineProperty<DuckingConfig>(const DuckingConfig());
  final _needMoreTracksController =
      StreamController<NeedMoreTracksEvent>.broadcast();

  late final List<_EngineProperty<Object?>> _allProperties;

  /// Action interface executing asynchronous playback, queue, and DSP controls.
  late final EngineAction<T> action;

  /// Reactive broadcast stream interface.
  late final EngineStream<T> stream;

  /// Synchronous state snapshot interface.
  late final EngineState<T> state;

  /// 3D Spatial Audio and Doppler effect controller.
  late final SpatialController spatial;

  /// Creates a [MiniaudioEngine] instance backed by Rust dual decks and lock-free mixer.
  MiniaudioEngine({
    int? bufferSize,
    AudioDevice? defaultAudioDevice,
    bool pauseOnDeviceChange = false,
    CrossfadeConfig? crossfadeConfig,
  }) {
    _bufferSize = _EngineProperty<int>(
      bufferSize ?? MiniaudioPlayer.globalConfig.defaultBufferSize,
    );
    _audioDevice = _EngineProperty<AudioDevice>(
      defaultAudioDevice ?? MiniaudioPlayer.globalConfig.defaultAudioDevice,
    );
    _pauseOnDeviceChange = _EngineProperty<bool>(pauseOnDeviceChange);
    _crossfadeConfig =
        _EngineProperty<CrossfadeConfig>(crossfadeConfig ?? CrossfadeConfig());
    _queueProp = _EngineProperty<List<AudioSource<T>>>(const []);
    _currentItem = _EngineProperty<AudioSource<T>?>(null);
    _currentData = _EngineProperty<T?>(null);

    _visualizer = _EngineProperty<VisualizerData>(
      VisualizerData.empty(),
      onListen: () {
        _hasVisualizerListeners = true;
        _updateVisualizerState();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _updateVisualizerState();
      },
    );

    _allProperties = <_EngineProperty<Object?>>[
      _phase,
      _position,
      _duration,
      _playing,
      _buffering,
      _completed,
      _opening,
      _playbackState,
      _bufferedPosition,
      _bufferedPercentage,
      _bufferedRange,
      _trackMetadata,
      _volume,
      _rate,
      _pitch,
      _bufferSize,
      _audioBitrate,
      _equalizer,
      _audioDevice,
      _pauseOnDeviceChange,
      _skipSilence,
      _silenceConfig,
      _silenceSavedDuration,
      _visualizer,
      _visualizerEnabled,
      _preamp,
      _replayGain,
      _balance,
      _mono,
      _crossfeed,
      _spatializerEnabled,
      _spatializerWidth,
      _reverb,
      _limiterEnabled,
      _queueProp,
      _currentIndex,
      _currentItem,
      _currentData,
      _hasNext,
      _hasPrevious,
      _shuffle,
      _loopMode,
      _crossfadeConfig,
      _isCrossfading,
      _volumeNormalization,
      _infiniteMix,
      _defaultReplayGain,
      _forcedReplayGain,
      _replayGainModeProp,
      _metaBytes,
      _isRecording,
      _isMicrophoneEnabled,
      _micVolume,
      _cueConfig,
      _duckingConfig,
    ];

    action = EngineAction<T>._(this);

    spatial = SpatialController(
      setEnabled: (enabled) {
        if (!_isDisposed) _rustEngine?.setSpatialEnabled(enabled: enabled);
      },
      setListener: (listener) {
        if (!_isDisposed) {
          _rustEngine?.setSpatialListener(listener: listener.toRust());
        }
      },
      setEmitter: (emitter) {
        if (!_isDisposed) {
          _rustEngine?.setSpatialEmitter(emitter: emitter.toRust());
        }
      },
      setDopplerFactor: (factor) {
        if (!_isDisposed) {
          _rustEngine?.setSpatialDopplerFactor(factor: factor);
        }
      },
      setSpeedOfSound: (speed) {
        if (!_isDisposed) {
          _rustEngine?.setSpatialSpeedOfSound(speed: speed);
        }
      },
    );

    stream = EngineStream<T>(
      phaseController: _phase.controller,
      positionController: _position.controller,
      durationController: _duration.controller,
      playingController: _playing.controller,
      bufferingController: _buffering.controller,
      completedController: _completed.controller,
      openingController: _opening.controller,
      playbackStateController: _playbackState.controller,
      bufferedPositionController: _bufferedPosition.controller,
      bufferedPercentageController: _bufferedPercentage.controller,
      bufferedRangeController: _bufferedRange.controller,
      trackMetadataController: _trackMetadata.controller,
      volumeController: _volume.controller,
      rateController: _rate.controller,
      pitchController: _pitch.controller,
      bufferSizeController: _bufferSize.controller,
      audioBitrateController: _audioBitrate.controller,
      equalizerController: _equalizer.controller,
      audioDeviceController: _audioDevice.controller,
      pauseOnDeviceChangeController: _pauseOnDeviceChange.controller,
      skipSilenceController: _skipSilence.controller,
      silenceConfigController: _silenceConfig.controller,
      silenceSavedDurationController: _silenceSavedDuration.controller,
      visualizerController: _visualizer.controller,
      visualizerEnabledController: _visualizerEnabled.controller,
      preampController: _preamp.controller,
      replayGainController: _replayGain.controller,
      balanceController: _balance.controller,
      monoController: _mono.controller,
      crossfeedController: _crossfeed.controller,
      spatializerEnabledController: _spatializerEnabled.controller,
      spatializerWidthController: _spatializerWidth.controller,
      reverbController: _reverb.controller,
      limiterEnabledController: _limiterEnabled.controller,
      queueController: _queueProp.controller,
      currentIndexController: _currentIndex.controller,
      currentItemController: _currentItem.controller,
      currentDataController: _currentData.controller,
      hasNextController: _hasNext.controller,
      hasPreviousController: _hasPrevious.controller,
      shuffleController: _shuffle.controller,
      loopModeController: _loopMode.controller,
      crossfadeConfigController: _crossfadeConfig.controller,
      isCrossfadingController: _isCrossfading.controller,
      volumeNormalizationController: _volumeNormalization.controller,
      infiniteMixController: _infiniteMix.controller,
      needMoreTracksController: _needMoreTracksController,
      defaultReplayGainController: _defaultReplayGain.controller,
      forcedReplayGainController: _forcedReplayGain.controller,
      replayGainModeController: _replayGainModeProp.controller,
      metaBytesController: _metaBytes.controller,
      isRecordingController: _isRecording.controller,
      isMicrophoneEnabledController: _isMicrophoneEnabled.controller,
      micVolumeController: _micVolume.controller,
      cueConfigController: _cueConfig.controller,
      duckingConfigController: _duckingConfig.controller,
    );

    state = EngineState<T>(
      getPhase: _resolveCurrentPhase,
      getPosition: _resolveCurrentPosition,
      getDuration: _resolveCurrentDuration,
      getPlaying: () => _rustEngine?.isPlaying() ?? _playing.value,
      getBuffering: () => _rustEngine?.isBuffering() ?? _buffering.value,
      getCompleted: () => _rustEngine?.isCompleted() ?? _completed.value,
      getOpening: () => _opening.value,
      getPlaybackState: () => _playbackState.value,
      getBufferedPosition: () => _bufferedPosition.value,
      getBufferedPercentage: () => _bufferedPercentage.value,
      getBufferedRange: () => _bufferedRange.value,
      getTrackMetadata: () => _trackMetadata.value,
      getVolume: () => _rustEngine?.getVolume() ?? _volume.value,
      getRate: () => _rate.value,
      getPitch: () => _pitch.value,
      getBufferSize: () => _bufferSize.value,
      getAudioBitrate: () => _audioBitrate.value,
      getSampleRate: () => 44100,
      getChannels: () => 2,
      getEqualizer: () => _equalizer.value,
      getAudioDevice: () => _audioDevice.value,
      getPauseOnDeviceChange: () => _pauseOnDeviceChange.value,
      getSkipSilence: () =>
          _silenceConfig.value.mode != SilenceSkipMode.disabled,
      getSilenceSkipMode: () => _silenceConfig.value.mode,
      getSilenceConfig: () => _silenceConfig.value,
      getSilenceSavedDuration: () => _silenceSavedDuration.value,
      getVisualizer: () => _visualizer.value,
      getVisualizerEnabled: () => _visualizerEnabled.value,
      getPreamp: () => _preamp.value,
      getReplayGain: () => _replayGain.value,
      getBalance: () => _balance.value,
      getMono: () => _mono.value,
      getCrossfeed: () => _crossfeed.value,
      getSpatializerEnabled: () => _spatializerEnabled.value,
      getSpatializerWidth: () => _spatializerWidth.value,
      getReverb: () => _reverb.value,
      getLimiterEnabled: () => _limiterEnabled.value,
      getQueue: () => List.unmodifiable(_queue),
      getOriginalQueue: () => List.unmodifiable(_queue),
      getCurrentIndex: _resolveActiveQueueIndex,
      getCurrentItem: () {
        final idx = _resolveActiveQueueIndex();
        return idx >= 0 && idx < _queue.length ? _queue[idx] : null;
      },
      getNextItem: () {
        final idx = _resolveActiveQueueIndex();
        return idx + 1 < _queue.length ? _queue[idx + 1] : null;
      },
      getHasNext: () {
        final idx = _resolveActiveQueueIndex();
        return idx + 1 < _queue.length || _loopMode.value == LoopMode.all;
      },
      getHasPrevious: () {
        final idx = _resolveActiveQueueIndex();
        return idx > 0 || _loopMode.value == LoopMode.all;
      },
      getShuffle: () => _shuffle.value,
      getLoopMode: () => _loopMode.value,
      getCrossfadeConfig: () => _crossfadeConfig.value,
      getIsCrossfading: () =>
          _phase.value == EnginePhase.autoCrossfading ||
          _phase.value == EnginePhase.manualCrossfading,
      getCrossfadeProgress: _resolveCrossfadeProgress,
      getVolumeNormalization: () => _volumeNormalization.value,
      getInfiniteMixEnabled: () => _infiniteMix.value,
      getIsLiveStream: _resolveIsLiveStream,
      getDefaultReplayGain: () => _defaultReplayGain.value,
      getForcedReplayGain: () => _forcedReplayGain.value,
      getReplayGainMode: () => _replayGainMode,
      getMetaBytes: () => _metaBytes.value,
      getIsRecording: () => _rustEngine?.isRecording() ?? _isRecording.value,
      getIsMicrophoneEnabled: () => _isMicrophoneEnabled.value,
      getMicVolume: () => _micVolume.value,
      getCueConfig: () => _cueConfig.value,
      getDuckingConfig: () => _duckingConfig.value,
    );

    MapLogger.info(
      'Initializing MiniaudioEngine (bufferSize: ${_bufferSize.value}, device: ${_audioDevice.value.id})',
    );

    _initFuture = _initRustEngine();
  }

  int? _optimisticIndex;

  int _resolveActiveQueueIndex() =>
      _optimisticIndex ??
      _rustEngine?.getCurrentIndex()?.toInt() ??
      _currentIndex.value;

  double _resolveCrossfadeProgress() {
    final phase = _resolveCurrentPhase();
    if (phase == EnginePhase.autoCrossfading) {
      final durMs = _resolveCurrentDuration().inMilliseconds;
      final posMs = _resolveCurrentPosition().inMilliseconds;
      final xfadeMs = _crossfadeConfig.value.duration.inMilliseconds;
      if (xfadeMs > 0 && durMs > xfadeMs) {
        final startMs = durMs - xfadeMs;
        return ((posMs - startMs) / xfadeMs).clamp(0.0, 1.0);
      }
    }
    return 0.0;
  }

  EnginePhase _resolveCurrentPhase() {
    if (_rustEngine != null) {
      final p = _rustEngine!.getPhase();
      if (p >= 0 && p < EnginePhase.values.length) {
        return EnginePhase.values[p];
      }
    }
    return _phase.value;
  }

  Duration _resolveCurrentPosition() {
    if (_rustEngine != null) {
      return Duration(milliseconds: _rustEngine!.getPositionMs().toInt());
    }
    return _position.value;
  }

  Duration _resolveCurrentDuration() {
    if (_rustEngine != null) {
      final ms = _rustEngine!.getDurationMs();
      if (ms > 0) return Duration(milliseconds: ms.toInt());
    }
    return _duration.value;
  }

  bool _resolveIsLiveStream() {
    if (_trackMetadata.value?.isLiveStream == true) return true;
    final idx = _resolveActiveQueueIndex();
    if (idx >= 0 && idx < _queue.length) {
      final src = _queue[idx];
      if (src is UriAudioSource<T>) {
        final s = src.sourceString.toLowerCase();
        return s.contains('/live') || s.endsWith('.m3u8');
      }
    }
    return false;
  }

  void _updateVisualizerState() {
    final effective = _manualVisualizerOverride ?? _hasVisualizerListeners;
    _visualizerEnabled.emit(effective);
    if (_rustEngine != null) {
      _rustEngine?.setVisualizerEnabled(enabled: effective);
    } else {
      _getEngine().then((eng) => eng?.setVisualizerEnabled(enabled: effective));
    }
  }

  ReplayGainMode get _replayGainMode {
    if (!_volumeNormalization.value) return ReplayGainMode.disabled;
    if (_forcedReplayGain.value != null) return ReplayGainMode.forced;
    return ReplayGainMode.track;
  }

  void _updateReplayGainForCurrentItem() {
    _replayGainModeProp.emit(_replayGainMode);
    if (!_volumeNormalization.value) {
      _replayGain.emit(const ReplayGainConfig());
      _rustEngine?.setReplayGain(gainDb: 0.0, peak: 1.0, preventClipping: true);
      return;
    }

    double gain = 0.0;
    double peak = 1.0;
    if (_forcedReplayGain.value != null) {
      gain = _forcedReplayGain.value!;
    } else {
      final idx = _resolveActiveQueueIndex();
      final cur = idx >= 0 && idx < _queue.length ? _queue[idx] : null;
      if (cur?.replayGainDb != null) {
        gain = cur!.replayGainDb!;
        peak = cur.replayPeak ?? 1.0;
      } else if (_defaultReplayGain.value != 0.0) {
        gain = _defaultReplayGain.value;
      }
    }

    final cfg = ReplayGainConfig(
      gainDb: gain,
      peak: peak,
      preventClipping: true,
      enabled: true,
    );
    _replayGain.emit(cfg);
    _rustEngine?.setReplayGain(gainDb: gain, peak: peak, preventClipping: true);
  }

  void _syncQueueNavigationTelemetry(int activeIdx) {
    _currentIndex.emit(activeIdx);
    final item =
        activeIdx >= 0 && activeIdx < _queue.length ? _queue[activeIdx] : null;
    _currentItem.emit(item);
    _currentData.emit(item?.data);
    _hasNext.emit(
      activeIdx + 1 < _queue.length || _loopMode.value == LoopMode.all,
    );
    _hasPrevious.emit(activeIdx > 0 || _loopMode.value == LoopMode.all);
    _updateReplayGainForCurrentItem();
  }

  Future<rust_engine.RustEngine?> _getEngine() async {
    if (_rustEngine != null) return _rustEngine;
    if (_isDisposed) return null;
    await (_initFuture ??= _initRustEngine());
    return _rustEngine;
  }

  Future<void> _initRustEngine() async {
    if (_rustEngine != null || _isDisposed) return;
    await ensureRustInitialized();
    if (_rustEngine != null || _isDisposed) return;
    try {
      final devId =
          (_audioDevice.value.id.isNotEmpty && _audioDevice.value.id != 'auto')
              ? _audioDevice.value.id
              : null;

      final engine = rust_engine.RustEngine(
        sampleRate: 0,
        channels: 0,
        periodSize: _bufferSize.value,
        playbackDeviceId: devId,
      );

      final xfade = _crossfadeConfig.value;
      engine.setCrossfadeConfig(
        config: rust_types.RustCrossfadeConfig(
          durationMs: BigInt.from(xfade.duration.inMilliseconds),
          manualDurationMs: BigInt.from(xfade.manualDuration.inMilliseconds),
          curve: xfade.curve.index,
        ),
      );

      if (spatial.isEnabled) {
        engine.setSpatialEnabled(enabled: true);
        engine.setSpatialListener(listener: spatial.listener.toRust());
        engine.setSpatialEmitter(emitter: spatial.emitter.toRust());
        engine.setSpatialDopplerFactor(factor: spatial.dopplerFactor);
        engine.setSpatialSpeedOfSound(speed: spatial.speedOfSound);
      }

      if (_visualizerEnabled.value) {
        engine.setVisualizerEnabled(enabled: true);
      }

      if (_isDisposed) {
        try {
          engine.dispose();
        } catch (_) {}
        return;
      }
      _eventSub = engine.subscribeEvents().listen(_handleRustEvent);
      _rustEngine = engine;
    } catch (e) {
      MapLogger.error('Failed to initialize RustEngine: $e');
    }
  }

  void _handleRustEvent(rust_types.RustEngineEvent event) {
    if (_isDisposed) return;

    switch (event) {
      case rust_types.RustEngineEvent_Phase(field0: final p):
        final nextPhase = p >= 0 && p < EnginePhase.values.length
            ? EnginePhase.values[p]
            : EnginePhase.idle;
        MapLogger.info('Engine telemetry phase -> $nextPhase');
        _phase.emit(nextPhase);
        _isCrossfading.emit(
          nextPhase == EnginePhase.autoCrossfading ||
              nextPhase == EnginePhase.manualCrossfading,
        );

      case rust_types.RustEngineEvent_State(field0: final s):
        final nextState = switch (s) {
          1 => PlaybackState.playing,
          2 => PlaybackState.paused,
          3 => PlaybackState.completed,
          4 => PlaybackState.buffering,
          5 => PlaybackState.error,
          6 => PlaybackState.opening,
          _ => PlaybackState.stopped,
        };
        MapLogger.info('Engine telemetry state -> $nextState');
        _playbackState.emit(nextState);

      case rust_types.RustEngineEvent_Position(field0: final p):
        MapLogger.verbose('Engine telemetry position -> ${p.toInt()}ms');
        _position.emit(Duration(milliseconds: p.toInt()));

      case rust_types.RustEngineEvent_Duration(field0: final d):
        MapLogger.info('Engine telemetry duration -> ${d.toInt()}ms');
        _duration.emit(Duration(milliseconds: d.toInt()));

      case rust_types.RustEngineEvent_IsPlaying(field0: final p):
        MapLogger.info('Engine telemetry isPlaying -> $p');
        _playing.emit(p);
        if (!p) {
          _visualizer.emit(VisualizerData.empty());
        }

      case rust_types.RustEngineEvent_IsBuffering(field0: final b):
        MapLogger.debug('Engine telemetry isBuffering -> $b');
        _buffering.emit(b);

      case rust_types.RustEngineEvent_IsCompleted(field0: final c):
        MapLogger.info('Engine telemetry isCompleted -> $c');
        _completed.emit(c);

      case rust_types.RustEngineEvent_CurrentIndex(field0: final idx):
        if (idx < 0 && _queue.isNotEmpty) break;
        MapLogger.info('Engine telemetry currentIndex -> $idx');
        _syncQueueNavigationTelemetry(idx);

      case rust_types.RustEngineEvent_QueueChanged(field0: final rItems):
        MapLogger.debug('Engine telemetry queueChanged -> ${rItems.length} items');
        _queue.clear();
        for (final r in rItems) {
          final id = r.id.toInt();
          final original = _shadowItems[id];
          _queue.add(
            original ??
                (AudioSource<T>(
                  r.source,
                  replayGainDb: r.replayGainDb,
                  replayPeak: r.replayPeak,
                )..attachEngineId(id)),
          );
        }
        _queueProp.emit(List.unmodifiable(_queue));
        _syncQueueNavigationTelemetry(_currentIndex.value);
        final activeIdx = _resolveActiveQueueIndex();
        if (activeIdx >= 0 && activeIdx < rItems.length) {
          final activeMeta = rItems[activeIdx].dataBytes;
          if (activeMeta != null && activeMeta.isNotEmpty) {
            _metaBytes.emit(activeMeta);
          }
        }

      case rust_types.RustEngineEvent_NeedMoreTracks(
          currentTrackId: final tid,
          remainingTracks: final rem,
        ):
        MapLogger.info('Engine telemetry needMoreTracks -> track: $tid, remaining: $rem');
        if (!_needMoreTracksController.isClosed) {
          _needMoreTracksController.add(
            NeedMoreTracksEvent(
              currentTrackId: tid.toInt(),
              remainingTracks: rem.toInt(),
            ),
          );
        }

      case rust_types.RustEngineEvent_Volume(field0: final v):
        MapLogger.debug('Engine telemetry volume -> $v');
        _volume.emit(v);

      case rust_types.RustEngineEvent_Visualizer(field0: final vz):
        MapLogger.verbose(
          'Engine telemetry visualizer -> rms: ${vz.rms.toStringAsFixed(4)}, peak: ${vz.peak.toStringAsFixed(4)}',
        );
        _visualizer.emit(
          VisualizerData(
            bands: vz.bands,
            rms: vz.rms,
            peak: vz.peak,
            left: vz.left,
            right: vz.right,
          ),
        );

      case rust_types.RustEngineEvent_VisualizerEnabled(field0: final en):
        MapLogger.debug('Engine telemetry visualizerEnabled -> $en');
        _visualizerEnabled.emit(en);

      case rust_types.RustEngineEvent_BufferedRange(field0: final br):
        final r = BufferedRange(
          start: Duration(milliseconds: br.startMs.toInt()),
          end: Duration(milliseconds: br.endMs.toInt()),
          duration: Duration(milliseconds: br.durationMs.toInt()),
          fillPercentage: br.fillPercentage,
          percentage: br.streamPercentage,
          isBuffering: br.isBuffering,
          isEof: br.isEof,
        );
        MapLogger.verbose(
          'Engine telemetry bufferedRange -> fill: ${(r.fillPercentage * 100).toStringAsFixed(1)}%, range: [${r.start.inMilliseconds}ms..${r.end.inMilliseconds}ms]',
        );
        _bufferedRange.emit(r);
        _bufferedPosition.emit(r.end);
        _bufferedPercentage.emit(r.percentage);

      case rust_types.RustEngineEvent_LoopMode(field0: final lm):
        final mode = LoopMode.values.elementAtOrNull(lm) ?? LoopMode.off;
        MapLogger.info('Engine telemetry loopMode -> $mode');
        _loopMode.emit(mode);

      case rust_types.RustEngineEvent_Shuffle(field0: final sh):
        MapLogger.info('Engine telemetry shuffle -> $sh');
        _shuffle.emit(sh);

      case rust_types.RustEngineEvent_CrossfadeConfig(field0: final cf):
        final curve = CrossfadeCurve.values.elementAtOrNull(cf.curve) ?? CrossfadeCurve.equalPower;
        final config = CrossfadeConfig(
          duration: Duration(milliseconds: cf.durationMs.toInt()),
          manualDuration: Duration(milliseconds: cf.manualDurationMs.toInt()),
          curve: curve,
        );
        MapLogger.debug('Engine telemetry crossfadeConfig -> $config');
        _crossfadeConfig.emit(config);

      case rust_types.RustEngineEvent_Error(
          message: final msg,
          code: final cd,
        ):
        MapLogger.error('Engine telemetry error: [$cd] $msg');

      default:
        break;
    }
  }

  Future<rust_types.RustAudioSource> _resolveRustAudioSource(
    AudioSource<T> item,
  ) async {
    final effectiveId = item.id ?? ++_nextAutoId;
    item.attachEngineId(effectiveId);
    _shadowItems[effectiveId] = item;

    if (item is UriAudioSource) {
      final s = item as UriAudioSource;
      final str = s.sourceString;
      if (str.startsWith('asset://') || str.startsWith('asset:')) {
        final key = str.startsWith('asset://')
            ? str.substring('asset://'.length)
            : str.substring('asset:'.length);
        final loader = MiniaudioPlayerGlobalConfig.assetLoader;
        if (loader != null) {
          try {
            final bytes = await loader(key);
            return rust_types.RustAudioSource(
              id: effectiveId,
              source: str,
              dataBytes: bytes,
              replayGainDb: item.replayGainDb,
              replayPeak: item.replayPeak,
            );
          } catch (_) {}
        }
      }
    }
    return item.toRustSource(effectiveId);
  }

  Future<void> _open(
    List<AudioSource<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) async {
    MapLogger.info(
      'Engine open -> ${items.length} items, startIndex: $startIndex, shuffle: $shuffle',
    );
    _shadowItems.clear();
    _nextAutoId = 0;
    _queue.clear();

    final effectiveStart = startIndex ?? 0;
    _currentIndex.value = effectiveStart;

    final engine = await _getEngine();
    final rustItems = <rust_types.RustAudioSource>[];
    for (final item in items) {
      rustItems.add(await _resolveRustAudioSource(item));
    }
    _queue.addAll(items);
    _queueProp.emit(List.unmodifiable(_queue));

    if (shuffle != _shuffle.value) {
      _shuffle.emit(shuffle);
      engine?.setShuffle(enabled: shuffle);
    }

    await engine?.setQueue(
      items: rustItems,
      startIndex: items.isNotEmpty ? BigInt.from(effectiveStart) : null,
    );

    if (items.isNotEmpty &&
        effectiveStart >= 0 &&
        effectiveStart < items.length) {
      _syncQueueNavigationTelemetry(effectiveStart);
    }
  }

  Future<void> _play() async {
    MapLogger.info('Engine play() requested');
    final engine = await _getEngine();
    engine?.play();
  }

  Future<void> _pause() async {
    MapLogger.info('Engine pause() requested');
    final engine = await _getEngine();
    engine?.pause();
  }

  Future<void> _stop() async {
    MapLogger.info('Engine stop() requested');
    final engine = await _getEngine();
    engine?.stop();
  }

  Future<void> _seek(Duration position) async {
    MapLogger.debug('Engine seek() requested -> ${position.inMilliseconds}ms');
    final engine = await _getEngine();
    engine?.seek(positionMs: position.inMilliseconds);
  }

  Future<void> _next() async {
    MapLogger.info('Engine next() requested');
    if (_queue.isNotEmpty) {
      final cur = _resolveActiveQueueIndex();
      if (cur + 1 < _queue.length) {
        _optimisticIndex = cur + 1;
        _syncQueueNavigationTelemetry(cur + 1);
      } else if (_loopMode.value == LoopMode.all) {
        _optimisticIndex = 0;
        _syncQueueNavigationTelemetry(0);
      }
    }
    final engine = await _getEngine();
    try {
      await engine?.next();
    } finally {
      _optimisticIndex = null;
    }
    _syncQueueNavigationTelemetry(_resolveActiveQueueIndex());
  }

  Future<void> _previous() async {
    MapLogger.info('Engine previous() requested');
    final engine = await _getEngine();
    await engine?.previous();
    _syncQueueNavigationTelemetry(_resolveActiveQueueIndex());
  }

  Future<void> _skipToIndex(int index) async {
    MapLogger.info('Engine skipToIndex() requested -> index: $index');
    if (index >= 0 && index < _queue.length) {
      _optimisticIndex = index;
      _syncQueueNavigationTelemetry(index);
    }
    final engine = await _getEngine();
    try {
      await engine?.skipToIndex(index: BigInt.from(index));
    } finally {
      _optimisticIndex = null;
    }
    _syncQueueNavigationTelemetry(_resolveActiveQueueIndex());
  }

  Future<void> _insertNext(AudioSource<T> item) async {
    final rustItem = await _resolveRustAudioSource(item);
    final engine = await _getEngine();
    await engine?.insertNext(item: rustItem);
  }

  Future<void> _append(List<AudioSource<T>> items) async {
    final rustItems = <rust_types.RustAudioSource>[];
    for (final item in items) {
      rustItems.add(await _resolveRustAudioSource(item));
    }
    final engine = await _getEngine();
    await engine?.append(items: rustItems);
  }

  Future<void> _removeAt(int index) async {
    final engine = await _getEngine();
    await engine?.removeAt(index: BigInt.from(index));
  }

  Future<void> _reorder(int from, int to) async {
    final engine = await _getEngine();
    await engine?.reorder(from: BigInt.from(from), to: BigInt.from(to));
  }

  Future<void> _clearQueue({bool keepCurrent = true}) async {
    final engine = await _getEngine();
    await engine?.clearQueue(keepCurrent: keepCurrent);
    if (!keepCurrent) {
      _shadowItems.clear();
    }
  }

  Future<void> _setShuffle(bool enabled) async {
    MapLogger.info('Engine setShuffle(enabled: $enabled)');
    _shuffle.emit(enabled);
    _rustEngine?.setShuffle(enabled: enabled);
  }

  Future<void> _setLoopMode(LoopMode mode) async {
    MapLogger.info('Engine setLoopMode(mode: $mode)');
    _loopMode.emit(mode);
    _rustEngine?.setLoopMode(mode: mode.index);
  }

  Future<void> _setCrossfadeConfig(CrossfadeConfig config) async {
    _crossfadeConfig.emit(config);
    _rustEngine?.setCrossfadeConfig(
      config: rust_types.RustCrossfadeConfig(
        durationMs: BigInt.from(config.duration.inMilliseconds),
        manualDurationMs: BigInt.from(config.manualDuration.inMilliseconds),
        curve: config.curve.index,
      ),
    );
  }

  Future<void> _setVolumeNormalization(bool enabled) async {
    _volumeNormalization.emit(enabled);
    _updateReplayGainForCurrentItem();
  }

  Future<void> _setDefaultReplayGain(double gainDb) async {
    _defaultReplayGain.emit(gainDb);
    _updateReplayGainForCurrentItem();
  }

  Future<void> _setForcedReplayGain(double? gainDb) async {
    _forcedReplayGain.emit(gainDb);
    _updateReplayGainForCurrentItem();
  }

  Future<void> _setInfiniteMix(bool enabled) async {
    _infiniteMix.emit(enabled);
    final engine = await _getEngine();
    engine?.setInfiniteMix(enabled: enabled);
  }

  Future<void> _setVolume(double volume) async {
    final clamped = volume.clamp(0.0, 2.0);
    _volume.emit(clamped);
    _rustEngine?.setVolume(volume: clamped);
  }

  Future<void> _setRate(double rate) async {
    final clamped = rate.clamp(0.1, 4.0);
    _rate.emit(clamped);
    _rustEngine?.setRate(rate: clamped);
  }

  Future<void> _setPitch(double pitch) async {
    final clamped = pitch.clamp(0.5, 2.0);
    _pitch.emit(clamped);
    _rustEngine?.setPitch(pitch: clamped);
  }

  Future<void> _setBufferSize(int bufferSize) async {
    _bufferSize.emit(bufferSize);
  }

  Future<void> _setEqualizer(Equalizer eq) async {
    _equalizer.emit(eq);
    _rustEngine?.setEqualizer(
      params: rust_types.RustEqualizerParams(
        gains: Float32List.fromList(eq.toList()),
        enabled: true,
      ),
    );
  }

  Future<void> _setDevice(AudioDevice device) async {
    _audioDevice.emit(device);
    if (device.id.isNotEmpty && device.id != 'auto') {
      _rustEngine?.setDevice(deviceId: device.id);
    }
  }

  void _setPauseOnDeviceChange(bool enabled) {
    if (_pauseOnDeviceChange.value == enabled) return;
    _pauseOnDeviceChange.emit(enabled);
  }

  Future<void> _setSkipSilence(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    final cur = _silenceConfig.value;
    final nextConfig = SilenceSkipConfig(
      mode: enabled ? mode : SilenceSkipMode.disabled,
      thresholdDb: thresholdDb ?? cur.thresholdDb,
      minSilenceDuration: minSilenceDuration ?? cur.minSilenceDuration,
      padding: padding ?? cur.padding,
    ).validated();
    await _setSilenceConfig(nextConfig);
  }

  Future<void> _setSilenceConfig(SilenceSkipConfig config) async {
    final valid = config.validated();
    _skipSilence.emit(valid.mode != SilenceSkipMode.disabled);
    _silenceConfig.emit(valid);
  }

  Future<void> _setVisualizerOverride(bool? enabled) async {
    _manualVisualizerOverride = enabled;
    _updateVisualizerState();
  }

  Future<void> _setReplayGain({
    required double gainDb,
    double? peak,
    bool preventClipping = true,
    bool force = false,
  }) async {
    if (force) {
      _forcedReplayGain.emit(gainDb);
    } else {
      _defaultReplayGain.emit(gainDb);
    }
    final cfg = ReplayGainConfig(
      gainDb: gainDb,
      peak: peak ?? 1.0,
      preventClipping: preventClipping,
      enabled: true,
    );
    _replayGain.emit(cfg);
    _replayGainModeProp.emit(_replayGainMode);
    _rustEngine?.setReplayGain(
      gainDb: gainDb,
      peak: peak ?? 1.0,
      preventClipping: preventClipping,
    );
  }

  Future<void> _clearReplayGain() async {
    _forcedReplayGain.emit(null);
    _defaultReplayGain.emit(0.0);
    _replayGain.emit(const ReplayGainConfig());
    _replayGainModeProp.emit(_replayGainMode);
    _rustEngine?.setReplayGain(gainDb: 0.0, peak: 1.0, preventClipping: true);
  }

  Future<void> _setPreamp(double preampDb) async {
    final clamped = preampDb.clamp(-24.0, 24.0);
    _preamp.emit(clamped);
    _rustEngine?.setPreamp(preampDb: clamped);
  }

  Future<void> _setBalance(double pan) async {
    final clamped = pan.clamp(-1.0, 1.0);
    _balance.emit(clamped);
    _rustEngine?.setBalance(balance: clamped);
  }

  Future<void> _setMono(bool enabled) async {
    _mono.emit(enabled);
    _rustEngine?.setMono(enabled: enabled);
  }

  Future<void> _setCrossfeed(CrossfeedMode mode) async {
    _crossfeed.emit(mode);
    _rustEngine?.setCrossfeed(mode: mode.index);
  }

  Future<void> _setSpatializer({
    required bool enabled,
    double width = 1.3,
  }) async {
    final clampedWidth = width.clamp(1.0, 2.0);
    _spatializerEnabled.emit(enabled);
    _spatializerWidth.emit(clampedWidth);
    _rustEngine?.setSpatializer(enabled: enabled, width: clampedWidth);
  }

  Future<void> _setLimiter(bool enabled) async {
    _limiterEnabled.emit(enabled);
    _rustEngine?.setLimiter(enabled: enabled);
  }

  Future<void> _setReverb(Reverb config) async {
    final valid = config.validated();
    _reverb.emit(valid);
    _rustEngine?.setReverb(
      params: rust_types.RustReverbParams(
        enabled: valid.enabled,
        roomSize: valid.roomSize,
        damping: valid.damping,
        width: valid.width,
        wet: valid.wet,
        dry: valid.dry,
        mode: 0.0,
      ),
    );
  }

  Future<void> _startRecording(
    String path, {
    WavFormat format = WavFormat.pcm16,
  }) async {
    final engine = await _getEngine();
    engine?.startRecording(path: path, format: format.toRust());
    _isRecording.emit(true);
  }

  Future<int> _stopRecording() async {
    final engine = await _getEngine();
    final bytes = engine?.stopRecording() ?? BigInt.zero;
    _isRecording.emit(false);
    return bytes.toInt();
  }

  bool _checkIsRecording() => _rustEngine?.isRecording() ?? _isRecording.value;

  Future<int> _offlineBounce(
    String path, {
    WavFormat format = WavFormat.pcm16,
    required Duration duration,
  }) async {
    final engine = await _getEngine();
    if (engine == null) return 0;
    final bytes = await engine.offlineBounce(
      path: path,
      format: format.toRust(),
      durationMs: duration.inMilliseconds,
    );
    return bytes.toInt();
  }

  Future<void> _enableMicrophone({
    String? captureDeviceId,
    bool autoDucking = true,
    double duckingDb = -14.0,
    double thresholdDb = -30.0,
  }) async {
    final engine = await _getEngine();
    engine?.enableMicrophone(
      captureDeviceId: captureDeviceId,
      autoDucking: autoDucking,
      duckingDb: duckingDb,
      thresholdDb: thresholdDb,
    );
    _isMicrophoneEnabled.emit(true);
    _duckingConfig.emit(
      DuckingConfig(
        enabled: autoDucking,
        duckingDb: duckingDb,
        thresholdDb: thresholdDb,
      ),
    );
  }

  Future<void> _disableMicrophone() async {
    final engine = await _getEngine();
    engine?.disableMicrophone();
    _isMicrophoneEnabled.emit(false);
  }

  Future<void> _setMicVolume(double volume) async {
    final v = volume.clamp(0.0, 2.0);
    _micVolume.emit(v);
    final engine = await _getEngine();
    engine?.setMicVolume(volume: v);
  }

  Future<void> _configureCueOutput({
    String? deviceId,
    double volume = 1.0,
    CueMode mode = CueMode.deckA,
  }) async {
    final v = volume.clamp(0.0, 2.0);
    final engine = await _getEngine();
    engine?.configureCueOutput(
      cueDeviceId: deviceId,
      volume: v,
      mode: mode.value,
    );
    _cueConfig.emit(
      CueConfig(
        enabled: true,
        deviceId: deviceId,
        volume: v,
        mode: mode,
      ),
    );
  }

  Future<void> _setCueVolume(double volume) async {
    final v = volume.clamp(0.0, 2.0);
    final cur = _cueConfig.value;
    _cueConfig.emit(
      CueConfig(
        enabled: cur.enabled,
        deviceId: cur.deviceId,
        volume: v,
        mode: cur.mode,
      ),
    );
    final engine = await _getEngine();
    engine?.setCueVolume(volume: v);
  }

  Future<void> _setCueMode(CueMode mode) async {
    final cur = _cueConfig.value;
    _cueConfig.emit(
      CueConfig(
        enabled: cur.enabled,
        deviceId: cur.deviceId,
        volume: cur.volume,
        mode: mode,
      ),
    );
    final engine = await _getEngine();
    engine?.setCueMode(mode: mode.value);
  }

  Future<void> _disableCueOutput() async {
    final engine = await _getEngine();
    engine?.disableCueOutput();
    final cur = _cueConfig.value;
    _cueConfig.emit(
      CueConfig(
        enabled: false,
        deviceId: cur.deviceId,
        volume: cur.volume,
        mode: cur.mode,
      ),
    );
  }

  Future<void> _configureOutputs({
    AudioDevice? masterDevice,
    AudioDevice? cueDevice,
    String? recordPath,
    WavFormat format = WavFormat.pcm16,
  }) async {
    if (masterDevice != null) {
      await _setDevice(masterDevice);
    }
    if (cueDevice != null) {
      await _configureCueOutput(
        deviceId: cueDevice.id == 'auto' || cueDevice.id.isEmpty
            ? null
            : cueDevice.id,
      );
    }
    if (recordPath != null) {
      await _startRecording(recordPath, format: format);
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    MapLogger.info('Disposing MiniaudioEngine instance');
    final engine = _rustEngine;
    _rustEngine = null;
    if (engine != null) {
      try {
        engine.stop();
        engine.dispose();
      } catch (_) {}
    }
    final sub = _eventSub;
    _eventSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }

    await _needMoreTracksController.close();
    for (final prop in _allProperties) {
      await prop.close();
    }
  }
}
