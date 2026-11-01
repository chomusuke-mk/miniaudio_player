import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../platform/native/native_backend.dart';
import '../reverb.dart';
import '../rust/api/engine.dart' as rust_engine;
import '../rust/api/types.dart' as rust_types;
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_action.dart';
import 'engine_item.dart';
import 'engine_state.dart';
import 'engine_stream.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'need_more_tracks_event.dart';
import 'player_state.dart' show PlaybackState;
import 'recording.dart';
import 'silence_skip_config.dart';
import 'spatial.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

/// Decoupled dual-deck audio engine with unified queue management,
/// sample-accurate crossfade interpolation in Rust, and composite visualizer processing.
class MiniaudioEngine<T> {
  rust_engine.RustEngine? _rustEngine;
  StreamSubscription<rust_types.RustEngineEvent>? _eventSub;
  bool _isDisposed = false;

  /// Whether this engine instance has been disposed.
  bool get isDisposed => _isDisposed;

  final List<EngineItem<T>> _queue = [];
  final Map<int, EngineItem<T>> _shadowItems = {};
  int _nextAutoId = 0;
  int _currentIndex = -1;
  LoopMode _loopMode = LoopMode.off;
  bool _shuffle = false;
  CrossfadeConfig _crossfadeConfig = CrossfadeConfig();
  bool _volumeNormalization = true;
  bool _infiniteMix = false;
  double _defaultReplayGain = 0.0;
  double? _forcedReplayGain;

  // Cached state snapshots
  EnginePhase _phase = EnginePhase.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  final bool _opening = false;
  PlaybackState _playbackState = PlaybackState.stopped;
  Duration _bufferedPosition = Duration.zero;
  double _bufferedPercentage = 0.0;
  BufferedRange _bufferedRange = const BufferedRange();
  AudioTrackMetadata? _trackMetadata;
  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;
  int _bufferSize = 0;
  final int _audioBitrate = 0;
  Equalizer _equalizer = Equalizer.flat;
  AudioDevice _audioDevice = AudioDevice.auto;
  bool _pauseOnDeviceChange = false;
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();
  final Duration _silenceSavedDuration = Duration.zero;
  VisualizerData _visualizer = VisualizerData.empty();
  bool _visualizerEnabled = false;
  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;
  double _preamp = 0.0;
  ReplayGainConfig _replayGain = const ReplayGainConfig();
  double _balance = 0.0;
  bool _mono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  double _spatializerWidth = 1.0;
  Reverb _reverb = Reverb.off;
  bool _limiterEnabled = true;
  bool _isRecording = false;
  bool _isMicrophoneEnabled = false;
  double _micVolume = 1.0;
  CueConfig _cueConfig = const CueConfig();
  DuckingConfig _duckingConfig = const DuckingConfig();

  // Broadcast stream controllers
  final _phaseController = StreamController<EnginePhase>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _bufferingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<bool>.broadcast();
  final _openingController = StreamController<bool>.broadcast();
  final _playbackStateController = StreamController<PlaybackState>.broadcast();
  final _bufferedPositionController = StreamController<Duration>.broadcast();
  final _bufferedPercentageController = StreamController<double>.broadcast();
  final _bufferedRangeController = StreamController<BufferedRange>.broadcast();
  final _trackMetadataController = StreamController<AudioTrackMetadata?>.broadcast();
  final _volumeController = StreamController<double>.broadcast();
  final _rateController = StreamController<double>.broadcast();
  final _pitchController = StreamController<double>.broadcast();
  final _bufferSizeController = StreamController<int>.broadcast();
  final _audioBitrateController = StreamController<int>.broadcast();
  final _equalizerController = StreamController<Equalizer>.broadcast();
  final _audioDeviceController = StreamController<AudioDevice>.broadcast();
  final _pauseOnDeviceChangeController = StreamController<bool>.broadcast();
  final _skipSilenceController = StreamController<bool>.broadcast();
  final _silenceConfigController = StreamController<SilenceSkipConfig>.broadcast();
  final _silenceSavedDurationController = StreamController<Duration>.broadcast();
  late final StreamController<VisualizerData> _visualizerController;
  final _visualizerEnabledController = StreamController<bool>.broadcast();
  final _preampController = StreamController<double>.broadcast();
  final _replayGainController = StreamController<ReplayGainConfig>.broadcast();
  final _balanceController = StreamController<double>.broadcast();
  final _monoController = StreamController<bool>.broadcast();
  final _crossfeedController = StreamController<CrossfeedMode>.broadcast();
  final _spatializerEnabledController = StreamController<bool>.broadcast();
  final _spatializerWidthController = StreamController<double>.broadcast();
  final _reverbController = StreamController<Reverb>.broadcast();
  final _limiterEnabledController = StreamController<bool>.broadcast();
  final _queueController = StreamController<List<EngineItem<T>>>.broadcast();
  final _currentIndexController = StreamController<int>.broadcast();
  final _currentItemController = StreamController<EngineItem<T>?>.broadcast();
  final _currentDataController = StreamController<T?>.broadcast();
  final _hasNextController = StreamController<bool>.broadcast();
  final _hasPreviousController = StreamController<bool>.broadcast();
  final _shuffleController = StreamController<bool>.broadcast();
  final _loopModeController = StreamController<LoopMode>.broadcast();
  final _crossfadeConfigController = StreamController<CrossfadeConfig>.broadcast();
  final _isCrossfadingController = StreamController<bool>.broadcast();
  final _volumeNormalizationController = StreamController<bool>.broadcast();
  final _infiniteMixController = StreamController<bool>.broadcast();
  final _needMoreTracksController = StreamController<NeedMoreTracksEvent>.broadcast();
  final _isRecordingController = StreamController<bool>.broadcast();
  final _isMicrophoneEnabledController = StreamController<bool>.broadcast();
  final _micVolumeController = StreamController<double>.broadcast();
  final _cueConfigController = StreamController<CueConfig>.broadcast();
  final _duckingConfigController = StreamController<DuckingConfig>.broadcast();

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
    _bufferSize = bufferSize ?? MiniaudioPlayer.globalConfig.defaultBufferSize;
    _audioDevice = defaultAudioDevice ?? MiniaudioPlayer.globalConfig.defaultAudioDevice;
    _pauseOnDeviceChange = pauseOnDeviceChange;
    _crossfadeConfig = crossfadeConfig ?? CrossfadeConfig();

    _visualizerController = StreamController<VisualizerData>.broadcast(
      onListen: () {
        _hasVisualizerListeners = true;
        _updateVisualizerState();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _updateVisualizerState();
      },
    );

    action = EngineAction<T>(this);

    spatial = SpatialController(
      setEnabled: (enabled) {
        if (_isDisposed) return;
        _rustEngine?.setSpatialEnabled(enabled: enabled);
      },
      setListener: (listener) {
        if (_isDisposed) return;
        _rustEngine?.setSpatialListener(listener: listener.toRust());
      },
      setEmitter: (emitter) {
        if (_isDisposed) return;
        _rustEngine?.setSpatialEmitter(emitter: emitter.toRust());
      },
      setDopplerFactor: (factor) {
        if (_isDisposed) return;
        _rustEngine?.setSpatialDopplerFactor(factor: factor);
      },
      setSpeedOfSound: (speed) {
        if (_isDisposed) return;
        _rustEngine?.setSpatialSpeedOfSound(speed: speed);
      },
    );

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
      pauseOnDeviceChangeController: _pauseOnDeviceChangeController,
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
      needMoreTracksController: _needMoreTracksController,
      isRecordingController: _isRecordingController,
      isMicrophoneEnabledController: _isMicrophoneEnabledController,
      micVolumeController: _micVolumeController,
      cueConfigController: _cueConfigController,
      duckingConfigController: _duckingConfigController,
    );

    state = EngineState<T>(
      getPhase: () {
        if (_rustEngine != null) {
          final p = _rustEngine!.getPhase();
          if (p >= 0 && p < EnginePhase.values.length) {
            return EnginePhase.values[p];
          }
        }
        return _phase;
      },
      getPosition: () {
        if (_rustEngine != null) {
          final ms = _rustEngine!.getPositionMs();
          return Duration(milliseconds: ms.toInt());
        }
        return _position;
      },
      getDuration: () {
        if (_rustEngine != null) {
          final ms = _rustEngine!.getDurationMs();
          if (ms > 0) return Duration(milliseconds: ms.toInt());
        }
        return _duration;
      },
      getPlaying: () => _rustEngine?.isPlaying() ?? _playing,
      getBuffering: () => _rustEngine?.isBuffering() ?? _buffering,
      getCompleted: () => _rustEngine?.isCompleted() ?? _completed,
      getOpening: () => _opening,
      getPlaybackState: () => _playbackState,
      getBufferedPosition: () => _bufferedPosition,
      getBufferedPercentage: () => _bufferedPercentage,
      getBufferedRange: () => _bufferedRange,
      getTrackMetadata: () => _trackMetadata,
      getVolume: () => _rustEngine?.getVolume() ?? _volume,
      getRate: () => _rate,
      getPitch: () => _pitch,
      getBufferSize: () => _bufferSize,
      getAudioBitrate: () => _audioBitrate,
      getSampleRate: () => 44100,
      getChannels: () => 2,
      getEqualizer: () => _equalizer,
      getAudioDevice: () => _audioDevice,
      getPauseOnDeviceChange: () => _pauseOnDeviceChange,
      getSkipSilence: () => _silenceConfig.mode != SilenceSkipMode.disabled,
      getSilenceSkipMode: () => _silenceConfig.mode,
      getSilenceConfig: () => _silenceConfig,
      getSilenceSavedDuration: () => _silenceSavedDuration,
      getVisualizer: () => _visualizer,
      getVisualizerEnabled: () => _visualizerEnabled,
      getPreamp: () => _preamp,
      getReplayGain: () => _replayGain,
      getBalance: () => _balance,
      getMono: () => _mono,
      getCrossfeed: () => _crossfeed,
      getSpatializerEnabled: () => _spatializerEnabled,
      getSpatializerWidth: () => _spatializerWidth,
      getReverb: () => _reverb,
      getLimiterEnabled: () => _limiterEnabled,
      getQueue: () => List.unmodifiable(_queue),
      getOriginalQueue: () => List.unmodifiable(_queue),
      getCurrentIndex: () => _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex,
      getCurrentItem: () {
        final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
        return idx >= 0 && idx < _queue.length ? _queue[idx] : null;
      },
      getNextItem: () {
        final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
        return idx + 1 < _queue.length ? _queue[idx + 1] : null;
      },
      getHasNext: () {
        final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
        return idx + 1 < _queue.length || _loopMode == LoopMode.all;
      },
      getHasPrevious: () {
        final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
        return idx > 0 || _loopMode == LoopMode.all;
      },
      getShuffle: () => _shuffle,
      getLoopMode: () => _loopMode,
      getCrossfadeConfig: () => _crossfadeConfig,
      getIsCrossfading: () => _phase == EnginePhase.autoCrossfading || _phase == EnginePhase.manualCrossfading,
      getCrossfadeProgress: () => 0.0,
      getVolumeNormalization: () => _volumeNormalization,
      getInfiniteMixEnabled: () => _infiniteMix,
      getIsLiveStream: () {
        if (_trackMetadata?.isLiveStream == true) return true;
        final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
        if (idx >= 0 && idx < _queue.length) {
          final cur = _queue[idx];
          final src = cur.source;
          if (src is UriAudioSource) {
            final s = src.sourceString.toLowerCase();
            if (s.contains('/live') || s.endsWith('.m3u8')) {
              return true;
            }
          }
        }
        return false;
      },
      getDefaultReplayGain: () => _defaultReplayGain,
      getForcedReplayGain: () => _forcedReplayGain,
      getReplayGainMode: () => _replayGainMode,
      getIsRecording: () => _rustEngine?.isRecording() ?? _isRecording,
      getIsMicrophoneEnabled: () => _isMicrophoneEnabled,
      getMicVolume: () => _micVolume,
      getCueConfig: () => _cueConfig,
      getDuckingConfig: () => _duckingConfig,
    );

    _initFuture = _initRustEngine();
  }

  void _updateVisualizerState() {
    final effective = _manualVisualizerOverride ?? _hasVisualizerListeners;
    _visualizerEnabled = effective;
    _visualizerEnabledController.add(effective);
    _rustEngine?.setVisualizerEnabled(enabled: effective);
  }

  ReplayGainMode get _replayGainMode {
    if (!_volumeNormalization) return ReplayGainMode.disabled;
    if (_forcedReplayGain != null) return ReplayGainMode.forced;
    return ReplayGainMode.track;
  }

  void _updateReplayGainForCurrentItem() {
    if (!_volumeNormalization) {
      _replayGain = const ReplayGainConfig();
      _replayGainController.add(_replayGain);
      _rustEngine?.setReplayGain(gainDb: 0.0, peak: 1.0, preventClipping: true);
      return;
    }
    double gain = 0.0;
    double peak = 1.0;
    if (_forcedReplayGain != null) {
      gain = _forcedReplayGain!;
    } else {
      final idx = _rustEngine?.getCurrentIndex()?.toInt() ?? _currentIndex;
      final cur = idx >= 0 && idx < _queue.length ? _queue[idx] : null;
      if (cur?.replayGainDb != null) {
        gain = cur!.replayGainDb!;
        peak = cur.replayPeak ?? 1.0;
      } else if (_defaultReplayGain != 0.0) {
        gain = _defaultReplayGain;
      }
    }
    _replayGain = ReplayGainConfig(
      gainDb: gain,
      peak: peak,
      preventClipping: true,
      enabled: true,
    );
    _replayGainController.add(_replayGain);
    _rustEngine?.setReplayGain(gainDb: gain, peak: peak, preventClipping: true);
  }

  Future<void>? _initFuture;

  Future<rust_engine.RustEngine?> _getEngine() async {
    if (_rustEngine != null) return _rustEngine;
    if (_isDisposed) return null;
    await (_initFuture ??= _initRustEngine());
    return _rustEngine;
  }

  Future<void> _initRustEngine() async {
    if (_rustEngine != null || _isDisposed) return;
    await NativePlayerBackend.ensureRustInitialized();
    if (_rustEngine != null || _isDisposed) return;
    try {
      final devId = (_audioDevice.id.isNotEmpty && _audioDevice.id != 'auto')
          ? _audioDevice.id
          : null;

      final engine = rust_engine.RustEngine(
        sampleRate: 0,
        channels: 0,
        periodSize: _bufferSize,
        playbackDeviceId: devId,
      );

      // Apply crossfade config synchronously
      engine.setCrossfadeConfig(
        config: rust_types.RustCrossfadeConfig(
          durationMs: BigInt.from(_crossfadeConfig.duration.inMilliseconds),
          manualDurationMs: BigInt.from(_crossfadeConfig.manualDuration.inMilliseconds),
          curve: _crossfadeConfig.curve.index,
        ),
      );

      if (spatial.isEnabled) {
        engine.setSpatialEnabled(enabled: true);
        engine.setSpatialListener(listener: spatial.listener.toRust());
        engine.setSpatialEmitter(emitter: spatial.emitter.toRust());
        engine.setSpatialDopplerFactor(factor: spatial.dopplerFactor);
        engine.setSpatialSpeedOfSound(speed: spatial.speedOfSound);
      }

      // Single unified event stream from Rust
      _eventSub = engine.subscribeEvents().listen(_handleRustEvent);
      _rustEngine = engine;
    } catch (e) {
      // ignore: avoid_print
      print('[miniaudio_player][ERROR][engine] Failed to initialize RustEngine: $e');
    }
  }

  void _handleRustEvent(rust_types.RustEngineEvent event) {
    if (_isDisposed) return;

    switch (event) {
      case rust_types.RustEngineEvent_Phase(field0: final p):
        _phase = EnginePhase.values.firstWhere(
          (e) => e.index == p,
          orElse: () => EnginePhase.idle,
        );
        _phaseController.add(_phase);
        final isXfading = _phase == EnginePhase.autoCrossfading || _phase == EnginePhase.manualCrossfading;
        _isCrossfadingController.add(isXfading);

      case rust_types.RustEngineEvent_State(field0: final s):
        _playbackState = switch (s) {
          1 => PlaybackState.playing,
          2 => PlaybackState.paused,
          3 => PlaybackState.completed,
          4 => PlaybackState.buffering,
          5 => PlaybackState.error,
          6 => PlaybackState.opening,
          _ => PlaybackState.stopped,
        };
        _playbackStateController.add(_playbackState);

      case rust_types.RustEngineEvent_Position(field0: final p):
        _position = Duration(milliseconds: p.toInt());
        _positionController.add(_position);

      case rust_types.RustEngineEvent_Duration(field0: final d):
        _duration = Duration(milliseconds: d.toInt());
        _durationController.add(_duration);

      case rust_types.RustEngineEvent_IsPlaying(field0: final p):
        _playing = p;
        _playingController.add(p);
        if (!p) {
          _visualizer = VisualizerData.empty();
          _visualizerController.add(_visualizer);
        }

      case rust_types.RustEngineEvent_IsBuffering(field0: final b):
        _buffering = b;
        _bufferingController.add(b);

      case rust_types.RustEngineEvent_IsCompleted(field0: final c):
        _completed = c;
        _completedController.add(c);

      case rust_types.RustEngineEvent_CurrentIndex(field0: final idx):
        if (idx < 0 && _queue.isNotEmpty) break;
        _currentIndex = idx;
        _currentIndexController.add(idx);
        final item = idx >= 0 && idx < _queue.length ? _queue[idx] : null;
        _currentItemController.add(item);
        _currentDataController.add(item?.data);
        _hasNextController.add(idx + 1 < _queue.length || _loopMode == LoopMode.all);
        _hasPreviousController.add(idx > 0 || _loopMode == LoopMode.all);
        _updateReplayGainForCurrentItem();

      case rust_types.RustEngineEvent_QueueChanged(field0: final rItems):
        _queue.clear();
        for (final r in rItems) {
          final id = r.id.toInt();
          final original = _shadowItems[id];
          if (original != null) {
            _queue.add(original);
          } else {
            _queue.add(EngineItem<T>(
              source: AudioSource(r.source),
              id: id,
              replayGainDb: r.replayGainDb,
              replayPeak: r.replayPeak,
            ));
          }
        }
        _queueController.add(List.unmodifiable(_queue));
        if (_currentIndex >= 0 && _currentIndex < _queue.length) {
          _currentItemController.add(_queue[_currentIndex]);
          _currentDataController.add(_queue[_currentIndex].data);
        }
        _hasNextController.add(_currentIndex + 1 < _queue.length || _loopMode == LoopMode.all);
        _hasPreviousController.add(_currentIndex > 0 || _loopMode == LoopMode.all);

      case rust_types.RustEngineEvent_NeedMoreTracks(
          currentTrackId: final tid,
          remainingTracks: final rem,
        ):
        _needMoreTracksController.add(NeedMoreTracksEvent(
          currentTrackId: tid.toInt(),
          remainingTracks: rem.toInt(),
        ));

      case rust_types.RustEngineEvent_Volume(field0: final v):
        _volume = v;
        _volumeController.add(v);

      case rust_types.RustEngineEvent_Visualizer(field0: final vz):
        _visualizer = VisualizerData(
          bands: vz.bands,
          rms: vz.rms,
          peak: vz.peak,
          left: vz.left,
          right: vz.right,
        );
        _visualizerController.add(_visualizer);

      case rust_types.RustEngineEvent_VisualizerEnabled(field0: final en):
        _visualizerEnabled = en;
        _visualizerEnabledController.add(en);

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
        _bufferedRange = r;
        _bufferedRangeController.add(r);
        _bufferedPosition = r.end;
        _bufferedPositionController.add(r.end);
        _bufferedPercentage = r.percentage;
        _bufferedPercentageController.add(r.percentage);

      case rust_types.RustEngineEvent_Error(message: final msg, code: final cd):
        // ignore: avoid_print
        print('[miniaudio_player][ERROR][engine] $msg ($cd)');

      default:
        break;
    }
  }

  // --- Internal Methods Invoked by EngineAction ---

  Future<void> openQueueInternal(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) async {
    _shadowItems.clear();
    _nextAutoId = 0;
    _queue.clear();

    final effectiveStart = startIndex ?? 0;
    _currentIndex = effectiveStart;

    final engine = await _getEngine();
    final rustItems = <rust_types.RustEngineItem>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final effectiveId = item.id ?? ++_nextAutoId;
      _shadowItems[effectiveId] = item;

      if (item.source is UriAudioSource) {
        final s = item.source as UriAudioSource;
        final str = s.sourceString;
        if (str.startsWith('asset://') || str.startsWith('asset:')) {
          final key = str.startsWith('asset://')
              ? str.substring('asset://'.length)
              : str.substring('asset:'.length);
          final loader = MiniaudioPlayerGlobalConfig.assetLoader;
          if (loader != null) {
            try {
              final bytes = await loader(key);
              rustItems.add(rust_types.RustEngineItem(
                id: effectiveId,
                source: str,
                dataBytes: bytes,
                replayGainDb: item.replayGainDb,
                replayPeak: item.replayPeak,
              ));
              continue;
            } catch (_) {}
          }
        }
      }
      rustItems.add(item.toRustItem(effectiveId));
    }
    _queue.addAll(items);
    _queueController.add(List.unmodifiable(_queue));

    engine?.setQueue(
      items: rustItems,
      startIndex: items.isNotEmpty ? BigInt.from(effectiveStart) : null,
    );

    if (items.isNotEmpty && effectiveStart >= 0 && effectiveStart < items.length) {
      _currentIndex = effectiveStart;
      _currentItemController.add(items[effectiveStart]);
      _currentDataController.add(items[effectiveStart].data);
      _currentIndexController.add(effectiveStart);
      _hasNextController.add(effectiveStart + 1 < items.length || _loopMode == LoopMode.all);
      _hasPreviousController.add(effectiveStart > 0 || _loopMode == LoopMode.all);
      _updateReplayGainForCurrentItem();
    }
  }

  Future<void> playInternal() async {
    final engine = await _getEngine();
    engine?.play();
  }

  Future<void> pauseInternal() async {
    final engine = await _getEngine();
    engine?.pause();
  }

  Future<void> togglePlayPauseInternal() async {
    if (_playing) {
      await pauseInternal();
    } else {
      await playInternal();
    }
  }

  Future<void> stopInternal() async {
    final engine = await _getEngine();
    engine?.stop();
  }

  Future<void> seekInternal(Duration position) async {
    final engine = await _getEngine();
    engine?.seek(positionMs: position.inMilliseconds);
  }

  Future<void> nextInternal() async {
    final engine = await _getEngine();
    engine?.next();
    _updateReplayGainForCurrentItem();
  }

  Future<void> previousInternal() async {
    final engine = await _getEngine();
    engine?.previous();
    _updateReplayGainForCurrentItem();
  }

  Future<void> skipToIndexInternal(int index) async {
    final engine = await _getEngine();
    engine?.skipToIndex(index: BigInt.from(index));
    _updateReplayGainForCurrentItem();
  }

  Future<void> insertNextInternal(EngineItem<T> item) async {
    final effectiveId = item.id ?? ++_nextAutoId;
    _shadowItems[effectiveId] = item;
    final engine = await _getEngine();
    engine?.insertNext(item: item.toRustItem(effectiveId));
  }

  Future<void> appendInternal(List<EngineItem<T>> items) async {
    final rustItems = <rust_types.RustEngineItem>[];
    for (final item in items) {
      final effectiveId = item.id ?? ++_nextAutoId;
      _shadowItems[effectiveId] = item;
      rustItems.add(item.toRustItem(effectiveId));
    }
    final engine = await _getEngine();
    engine?.append(items: rustItems);
  }

  Future<void> removeAtInternal(int index) async {
    final engine = await _getEngine();
    engine?.removeAt(index: BigInt.from(index));
  }

  Future<void> reorderInternal(int from, int to) async {
    final engine = await _getEngine();
    engine?.reorder(from: BigInt.from(from), to: BigInt.from(to));
  }

  Future<void> clearQueueInternal({bool keepCurrent = true}) async {
    final engine = await _getEngine();
    engine?.clearQueue(keepCurrent: keepCurrent);
    if (!keepCurrent) {
      _shadowItems.clear();
    }
  }

  Future<void> setShuffleInternal(bool enabled) async {
    _shuffle = enabled;
    _shuffleController.add(enabled);
    _rustEngine?.setShuffle(enabled: enabled);
  }

  Future<bool> toggleShuffleInternal() async {
    final next = !_shuffle;
    await setShuffleInternal(next);
    return next;
  }

  Future<void> setLoopModeInternal(LoopMode mode) async {
    _loopMode = mode;
    _loopModeController.add(mode);
    _rustEngine?.setLoopMode(mode: mode.index);
  }

  Future<LoopMode> cycleLoopModeInternal() async {
    final next = _loopMode.next();
    await setLoopModeInternal(next);
    return next;
  }

  Future<void> setCrossfadeConfigInternal(CrossfadeConfig config) async {
    _crossfadeConfig = config;
    _crossfadeConfigController.add(config);
    _rustEngine?.setCrossfadeConfig(
      config: rust_types.RustCrossfadeConfig(
        durationMs: BigInt.from(config.duration.inMilliseconds),
        manualDurationMs: BigInt.from(config.manualDuration.inMilliseconds),
        curve: config.curve.index,
      ),
    );
  }

  Future<void> setVolumeNormalizationInternal(bool enabled) async {
    _volumeNormalization = enabled;
    _volumeNormalizationController.add(enabled);
    _updateReplayGainForCurrentItem();
  }

  Future<void> setDefaultReplayGainInternal(double gainDb) async {
    _defaultReplayGain = gainDb;
    _updateReplayGainForCurrentItem();
  }

  Future<void> setForcedReplayGainInternal(double? gainDb) async {
    _forcedReplayGain = gainDb;
    _updateReplayGainForCurrentItem();
  }

  Future<void> setInfiniteMixInternal(bool enabled) async {
    _infiniteMix = enabled;
    _infiniteMixController.add(enabled);
    final engine = await _getEngine();
    engine?.setInfiniteMix(enabled: enabled);
  }

  Future<void> setVolumeInternal(double volume) async {
    _volume = volume;
    _volumeController.add(volume);
    _rustEngine?.setVolume(volume: volume);
  }

  Future<void> setRateInternal(double rate) async {
    _rate = rate;
    _rateController.add(rate);
    _rustEngine?.setRate(rate: rate);
  }

  Future<void> setPitchInternal(double pitch) async {
    _pitch = pitch;
    _pitchController.add(pitch);
    _rustEngine?.setPitch(pitch: pitch);
  }

  Future<void> setBufferSizeInternal(int bufferSize) async {
    _bufferSize = bufferSize;
    _bufferSizeController.add(bufferSize);
  }

  void setIcyMetaInternal(Uint8List data) {}
  void probeTailInternal(Uint8List data, int tailOffset) {}

  Future<void> setEqualizerInternal(Equalizer eq) async {
    _equalizer = eq;
    _equalizerController.add(eq);
    _rustEngine?.setEqualizer(
      params: rust_types.RustEqualizerParams(gains: Float32List.fromList(eq.toList()), enabled: true),
    );
  }

  Future<void> setDeviceInternal(AudioDevice device) async {
    _audioDevice = device;
    _audioDeviceController.add(device);
    if (device.id.isNotEmpty && device.id != 'auto') {
      _rustEngine?.setDevice(deviceId: device.id);
    }
  }

  void setPauseOnDeviceChangeInternal(bool enabled) {
    if (_pauseOnDeviceChange == enabled) return;
    _pauseOnDeviceChange = enabled;
    _pauseOnDeviceChangeController.add(enabled);
  }

  Future<void> setSkipSilenceInternal(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    _silenceConfig = SilenceSkipConfig(
      mode: enabled ? mode : SilenceSkipMode.disabled,
      thresholdDb: thresholdDb ?? _silenceConfig.thresholdDb,
      minSilenceDuration: minSilenceDuration ?? _silenceConfig.minSilenceDuration,
      padding: padding ?? _silenceConfig.padding,
    );
    _silenceConfigController.add(_silenceConfig);
  }

  Future<void> setSilenceConfigInternal(SilenceSkipConfig config) async {
    _silenceConfig = config;
    _silenceConfigController.add(config);
  }

  Future<void> setVisualizerOverrideInternal(bool? enabled) async {
    _manualVisualizerOverride = enabled;
    _updateVisualizerState();
  }

  Future<void> setReplayGainInternal({
    required double gainDb,
    double? peak,
    bool preventClipping = true,
    bool force = false,
  }) async {
    _replayGain = ReplayGainConfig(
      gainDb: gainDb,
      peak: peak ?? 1.0,
      preventClipping: preventClipping,
      enabled: true,
    );
    _replayGainController.add(_replayGain);
  }

  Future<void> clearReplayGainInternal() async {
    _replayGain = const ReplayGainConfig();
    _replayGainController.add(_replayGain);
  }

  Future<void> setPreampInternal(double preampDb) async {
    _preamp = preampDb;
    _preampController.add(preampDb);
    _rustEngine?.setPreamp(preampDb: preampDb);
  }

  Future<void> setBalanceInternal(double pan) async {
    _balance = pan;
    _balanceController.add(pan);
    _rustEngine?.setBalance(balance: pan);
  }

  Future<void> setMonoInternal(bool enabled) async {
    _mono = enabled;
    _monoController.add(enabled);
    _rustEngine?.setMono(enabled: enabled);
  }

  Future<void> setCrossfeedInternal(CrossfeedMode mode) async {
    _crossfeed = mode;
    _crossfeedController.add(mode);
    _rustEngine?.setCrossfeed(mode: mode.index);
  }

  Future<void> setSpatializerInternal({
    required bool enabled,
    double width = 1.3,
  }) async {
    _spatializerEnabled = enabled;
    _spatializerWidth = width;
    _spatializerEnabledController.add(enabled);
    _spatializerWidthController.add(width);
    _rustEngine?.setSpatializer(enabled: enabled, width: width);
  }

  Future<void> setLimiterInternal(bool enabled) async {
    _limiterEnabled = enabled;
    _limiterEnabledController.add(enabled);
    _rustEngine?.setLimiter(enabled: enabled);
  }

  Future<void> setReverbInternal(Reverb config) async {
    _reverb = config;
    _reverbController.add(config);
    _rustEngine?.setReverb(
      params: rust_types.RustReverbParams(
        enabled: config.enabled,
        roomSize: config.roomSize,
        damping: config.damping,
        width: config.width,
        wet: config.wet,
        dry: config.dry,
        mode: 0.0,
      ),
    );
  }

  // --------------------------------------------------------------------------
  // Sinks Desacoplados, Grabación & Pre-escucha Cue
  // --------------------------------------------------------------------------

  Future<void> startRecordingInternal(
    String path, {
    WavFormat format = WavFormat.pcm16,
  }) async {
    final engine = await _getEngine();
    engine?.startRecording(path: path, format: format.toRust());
    _isRecording = true;
    _isRecordingController.add(true);
  }

  Future<int> stopRecordingInternal() async {
    final engine = await _getEngine();
    final bytes = engine?.stopRecording() ?? BigInt.zero;
    _isRecording = false;
    _isRecordingController.add(false);
    return bytes.toInt();
  }

  bool isRecordingInternal() {
    return _rustEngine?.isRecording() ?? _isRecording;
  }

  Future<int> offlineBounceInternal(
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

  Future<void> enableMicrophoneInternal({
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
    _isMicrophoneEnabled = true;
    _isMicrophoneEnabledController.add(true);
    _duckingConfig = DuckingConfig(
      enabled: autoDucking,
      duckingDb: duckingDb,
      thresholdDb: thresholdDb,
    );
    _duckingConfigController.add(_duckingConfig);
  }

  Future<void> disableMicrophoneInternal() async {
    final engine = await _getEngine();
    engine?.disableMicrophone();
    _isMicrophoneEnabled = false;
    _isMicrophoneEnabledController.add(false);
  }

  Future<void> setMicVolumeInternal(double volume) async {
    final v = volume.clamp(0.0, 2.0);
    _micVolume = v;
    _micVolumeController.add(v);
    final engine = await _getEngine();
    engine?.setMicVolume(volume: v);
  }

  Future<void> configureCueOutputInternal({
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
    _cueConfig = CueConfig(
      enabled: true,
      deviceId: deviceId,
      volume: v,
      mode: mode,
    );
    _cueConfigController.add(_cueConfig);
  }

  Future<void> setCueVolumeInternal(double volume) async {
    final v = volume.clamp(0.0, 2.0);
    _cueConfig = CueConfig(
      enabled: _cueConfig.enabled,
      deviceId: _cueConfig.deviceId,
      volume: v,
      mode: _cueConfig.mode,
    );
    _cueConfigController.add(_cueConfig);
    final engine = await _getEngine();
    engine?.setCueVolume(volume: v);
  }

  Future<void> setCueModeInternal(CueMode mode) async {
    _cueConfig = CueConfig(
      enabled: _cueConfig.enabled,
      deviceId: _cueConfig.deviceId,
      volume: _cueConfig.volume,
      mode: mode,
    );
    _cueConfigController.add(_cueConfig);
    final engine = await _getEngine();
    engine?.setCueMode(mode: mode.value);
  }

  Future<void> disableCueOutputInternal() async {
    final engine = await _getEngine();
    engine?.disableCueOutput();
    _cueConfig = CueConfig(
      enabled: false,
      deviceId: _cueConfig.deviceId,
      volume: _cueConfig.volume,
      mode: _cueConfig.mode,
    );
    _cueConfigController.add(_cueConfig);
  }

  Future<void> configureOutputsInternal({
    AudioDevice? masterDevice,
    AudioDevice? cueDevice,
    String? recordPath,
    WavFormat format = WavFormat.pcm16,
  }) async {
    if (masterDevice != null) {
      await setDeviceInternal(masterDevice);
    }
    if (cueDevice != null) {
      await configureCueOutputInternal(
        deviceId: cueDevice.id == 'auto' || cueDevice.id.isEmpty ? null : cueDevice.id,
      );
    }
    if (recordPath != null) {
      await startRecordingInternal(recordPath, format: format);
    }
  }

  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _eventSub?.cancel();
    _eventSub = null;
    _rustEngine?.stop();
    _rustEngine = null;

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
    await _pauseOnDeviceChangeController.close();
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
    await _needMoreTracksController.close();
    await _isRecordingController.close();
    await _isMicrophoneEnabledController.close();
    await _micVolumeController.close();
    await _cueConfigController.close();
    await _duckingConfigController.close();
  }
}
