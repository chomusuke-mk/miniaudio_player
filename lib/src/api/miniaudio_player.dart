import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../platform/platform_backend.dart';
import '../platform/platform_select.dart';
import '../reverb.dart';
import 'audio_analysis_result.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'dsp_config.dart';
import 'player_action.dart';
import 'player_exception.dart';
import 'player_state.dart';
import 'player_stream.dart';
import 'silence_skip_config.dart';
import 'spatial.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

/// Supported audio file extensions natively decoded by [MiniaudioPlayer].
const List<String> miniAudioPlayerSupportedExtensions = [
  'mp3',
  'wav',
  'flac',
  'ogg',
  'opus',
  'aif',
  'aiff',
  'aifc',
  'w64',
  'rf64',
  'bwf',
  'rifx',
  'mp2',
  'mp1',
  'oga',
  'aac',
  'm4a',
  'webm',
  'mkv',
  'mka',
  'caf',
];

/// Logging severity levels for miniaudio and internal player engine.
enum MiniaudioLogLevel {
  none(0),
  error(1),
  warning(2),
  info(3),
  debug(4),
  verbose(5);

  final int value;
  const MiniaudioLogLevel(this.value);

  static MiniaudioLogLevel fromValue(int value) {
    for (final level in MiniaudioLogLevel.values) {
      if (level.value == value) return level;
    }
    return MiniaudioLogLevel.none;
  }
}

/// Resolves the user-facing display name for the system default audio device.
typedef DefaultDeviceDisplayNameResolver = String Function(String resolvedName);

/// Optional resolver for loading Flutter bundle assets.
typedef AssetBytesLoader = Future<Uint8List> Function(String assetKey);

/// Global configuration container for [MiniaudioPlayer].
class MiniaudioPlayerGlobalConfig {
  /// Optional global loader for resolving Flutter assets.
  static AssetBytesLoader? assetLoader;

  /// Default period buffer size in frames applied when instantiating new players.
  int defaultBufferSize;

  /// Global log level controlling native and engine log output.
  MiniaudioLogLevel logLevel;

  /// Default audio output device applied when instantiating new players.
  AudioDevice defaultAudioDevice;

  /// Resolver function to format the user-friendly [AudioDevice.displayName]
  /// when an audio device is set to automatic/system default routing.
  DefaultDeviceDisplayNameResolver defaultDeviceDisplayNameResolver;

  /// Default ahead buffer duration for local files (default: 30s).
  Duration bufferLocalDuration;

  /// Default ahead buffer duration for progressive network streams (default: 30s).
  Duration bufferNetworkDuration;

  /// Default ahead buffer duration for continuous live streams (default: 15s).
  Duration bufferLiveStreamDuration;

  /// Default behind buffer duration retained in circular RAM cache for local files (default: 10s).
  Duration bufferBehindLocalDuration;

  /// Default behind buffer duration retained in circular RAM cache for network streams (default: 15s).
  Duration bufferBehindNetworkDuration;

  /// Default behind buffer duration retained in circular RAM cache for live streams (default: 5s).
  Duration bufferBehindLiveStreamDuration;

  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
    this.defaultAudioDevice = AudioDevice.auto,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    this.bufferLocalDuration = const Duration(seconds: 30),
    this.bufferNetworkDuration = const Duration(seconds: 30),
    this.bufferLiveStreamDuration = const Duration(seconds: 15),
    this.bufferBehindLocalDuration = const Duration(seconds: 10),
    this.bufferBehindNetworkDuration = const Duration(seconds: 15),
    this.bufferBehindLiveStreamDuration = const Duration(seconds: 5),
  }) : defaultDeviceDisplayNameResolver = defaultDeviceDisplayNameResolver ??
            _defaultDeviceDisplayNameResolver;

  static String _defaultDeviceDisplayNameResolver(String resolvedName) {
    final clean = resolvedName.trim();
    return clean.isEmpty ? 'System Default' : 'System Default ($clean)';
  }
}

/// Encapsulates a synchronous state snapshot paired with a deduplicated broadcast [StreamController].
class _ReactiveProperty<T> {
  T _value;
  T _lastEmitted;
  final StreamController<T> controller;

  _ReactiveProperty(
    T initialValue, {
    void Function()? onListen,
    void Function()? onCancel,
  })  : _value = initialValue,
        _lastEmitted = initialValue,
        controller = StreamController<T>.broadcast(
          onListen: onListen,
          onCancel: onCancel,
        );

  T get value => _value;

  void setSnapshot(T nextValue) {
    _value = nextValue;
  }

  void emitIfChanged(T nextValue) {
    _value = nextValue;
    if (_lastEmitted == nextValue) return;
    _lastEmitted = nextValue;
    if (!controller.isClosed) {
      controller.add(nextValue);
    }
  }

  void forceEmit(T nextValue) {
    _value = nextValue;
    _lastEmitted = nextValue;
    if (!controller.isClosed) {
      controller.add(nextValue);
    }
  }

  Future<void> close() => controller.close();
}

/// Cross-platform, ultra-low-resource audio player for Flutter and Web.
class MiniaudioPlayer implements PlayerBackendListener {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  /// Currently active global player configuration.
  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;

  /// Broadcast stream of system audio output device list changes.
  static Stream<List<AudioDevice>> getAudioDevicesStream() =>
      getPlatformService().getAudioDevicesStream();

  /// Global configuration accessor and updater for [MiniaudioPlayer].
  static MiniaudioPlayerGlobalConfig config({
    int? defaultBufferSize,
    MiniaudioLogLevel? logLevel,
    AudioDevice? defaultAudioDevice,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    Duration? bufferBehindLocalDuration,
    Duration? bufferBehindNetworkDuration,
    Duration? bufferBehindLiveStreamDuration,
    AssetBytesLoader? assetLoader,
  }) {
    if (assetLoader != null) {
      MiniaudioPlayerGlobalConfig.assetLoader = assetLoader;
    }
    if (defaultBufferSize != null) {
      if (defaultBufferSize < 0) {
        throw ArgumentError.value(
          defaultBufferSize,
          'defaultBufferSize',
          'Buffer size must be non-negative',
        );
      }
      _globalConfig.defaultBufferSize = defaultBufferSize;
    }
    if (logLevel != null) {
      _globalConfig.logLevel = logLevel;
      try {
        getPlatformService().setLogLevel(logLevel.value);
      } catch (_) {}
    }
    if (defaultAudioDevice != null) {
      _globalConfig.defaultAudioDevice = defaultAudioDevice;
    }
    if (defaultDeviceDisplayNameResolver != null) {
      _globalConfig.defaultDeviceDisplayNameResolver =
          defaultDeviceDisplayNameResolver;
    }
    if (bufferLocalDuration != null) {
      _globalConfig.bufferLocalDuration = bufferLocalDuration;
    }
    if (bufferNetworkDuration != null) {
      _globalConfig.bufferNetworkDuration = bufferNetworkDuration;
    }
    if (bufferLiveStreamDuration != null) {
      _globalConfig.bufferLiveStreamDuration = bufferLiveStreamDuration;
    }
    if (bufferBehindLocalDuration != null) {
      _globalConfig.bufferBehindLocalDuration = bufferBehindLocalDuration;
    }
    if (bufferBehindNetworkDuration != null) {
      _globalConfig.bufferBehindNetworkDuration = bufferBehindNetworkDuration;
    }
    if (bufferBehindLiveStreamDuration != null) {
      _globalConfig.bufferBehindLiveStreamDuration =
          bufferBehindLiveStreamDuration;
    }
    return _globalConfig;
  }

  /// Enumerates all available playback audio devices on the system.
  static Future<List<AudioDevice>> getAudioDevices() =>
      getPlatformService().getAudioDevices();

  /// Synchronous enumeration of all available playback audio devices on the system.
  static List<AudioDevice> getAudioDevicesSync() =>
      getPlatformService().getAudioDevicesSync();

  /// Enumerates all available capture (microphone / line-in) audio devices on the system.
  static Future<List<AudioDevice>> getCaptureDevices() =>
      getPlatformService().getCaptureDevices();

  /// Synchronous enumeration of all available capture (microphone / line-in) audio devices on the system.
  static List<AudioDevice> getCaptureDevicesSync() =>
      getPlatformService().getCaptureDevicesSync();

  /// Analyzes an audio file in a single, high-performance decoding pass.
  static Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) =>
      getPlatformService().analyzeAudio(
        filePath,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );

  /// Synchronously analyzes an audio file in a single decoding pass.
  static AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) =>
      getPlatformService().analyzeAudioSync(
        filePath,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );

  /// Analyzes audio directly from memory bytes.
  static Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) =>
      getPlatformService().analyzeAudioMemory(
        bytes,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );

  late final PlayerBackend _backend;

  /// Internal platform backend instance.
  PlayerBackend get backend => _backend;

  // Reactive state properties
  final _position = _ReactiveProperty<Duration>(Duration.zero);
  final _duration = _ReactiveProperty<Duration>(Duration.zero);
  final _playing = _ReactiveProperty<bool>(false);
  final _buffering = _ReactiveProperty<bool>(false);
  final _completed = _ReactiveProperty<bool>(false);
  final _opening = _ReactiveProperty<bool>(false);
  final _playbackState = _ReactiveProperty<PlaybackState>(PlaybackState.stopped);
  final _bufferedPosition = _ReactiveProperty<Duration>(Duration.zero);
  final _bufferedPercentage = _ReactiveProperty<double>(0.0);
  final _bufferedRange = _ReactiveProperty<BufferedRange>(const BufferedRange());
  final _trackMetadata = _ReactiveProperty<AudioTrackMetadata?>(null);
  final _volume = _ReactiveProperty<double>(1.0);
  final _rate = _ReactiveProperty<double>(1.0);
  final _pitch = _ReactiveProperty<double>(1.0);
  late final _ReactiveProperty<int> _bufferSize;
  final _audioBitrate = _ReactiveProperty<int>(0);
  final _equalizer = _ReactiveProperty<Equalizer>(Equalizer.flat);
  late final _ReactiveProperty<AudioDevice> _audioDevice;
  late final _ReactiveProperty<bool> _pauseOnDeviceChange;
  final _skipSilence = _ReactiveProperty<bool>(false);
  final _silenceConfig =
      _ReactiveProperty<SilenceSkipConfig>(const SilenceSkipConfig());
  final _silenceSavedDuration = _ReactiveProperty<Duration>(Duration.zero);
  late final _ReactiveProperty<VisualizerData> _visualizer;
  final _visualizerEnabled = _ReactiveProperty<bool>(false);
  final _preamp = _ReactiveProperty<double>(0.0);
  final _replayGain =
      _ReactiveProperty<ReplayGainConfig>(const ReplayGainConfig());
  final _balance = _ReactiveProperty<double>(0.0);
  final _mono = _ReactiveProperty<bool>(false);
  final _crossfeed = _ReactiveProperty<CrossfeedMode>(CrossfeedMode.off);
  final _spatializerEnabled = _ReactiveProperty<bool>(false);
  final _spatializerWidth = _ReactiveProperty<double>(1.0);
  final _reverb = _ReactiveProperty<Reverb>(Reverb.off);
  final _limiterEnabled = _ReactiveProperty<bool>(true);
  final _metaBytes = _ReactiveProperty<Uint8List?>(null);

  late final List<_ReactiveProperty<Object?>> _allProperties;

  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;
  bool _isDisposed = false;

  bool get _isVisualizerActive =>
      _manualVisualizerOverride ?? _hasVisualizerListeners;

  /// Action interface for controlling playback, volume, rate, pitch, buffer size, and DSP.
  late final PlayerAction action;

  /// Reactive stream interface for observing state changes.
  late final PlayerStream stream;

  /// Synchronous state snapshot interface.
  late final PlayerState state;

  /// 3D Spatial Audio and Doppler effect controller.
  late final SpatialController spatial;

  /// Creates a [MiniaudioPlayer] instance bound to the provided [AudioSource].
  MiniaudioPlayer(
    AudioSource source, {
    int? bufferSize,
    AudioDevice? defaultAudioDevice,
    bool pauseOnDeviceChange = false,
  }) {
    _bufferSize = _ReactiveProperty<int>(
      bufferSize ?? _globalConfig.defaultBufferSize,
    );
    _audioDevice = _ReactiveProperty<AudioDevice>(
      defaultAudioDevice ?? _globalConfig.defaultAudioDevice,
    );
    _pauseOnDeviceChange = _ReactiveProperty<bool>(pauseOnDeviceChange);
    _visualizer = _ReactiveProperty<VisualizerData>(
      VisualizerData.empty(),
      onListen: () {
        _hasVisualizerListeners = true;
        _updateNativeVisualizerState();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _updateNativeVisualizerState();
      },
    );

    _allProperties = <_ReactiveProperty<Object?>>[
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
      _metaBytes,
    ];

    if (_globalConfig.logLevel.value > 0) {
      try {
        getPlatformService().setLogLevel(_globalConfig.logLevel.value);
      } catch (_) {}
    }

    _backend = createPlayerBackend(this);
    _backend.setListener(this);

    final devId =
        (_audioDevice.value.id.isNotEmpty && _audioDevice.value.id != 'auto')
            ? _audioDevice.value.id
            : null;

    _backend.init(
      sampleRate: 0,
      channels: 0,
      periodSize: _bufferSize.value > 0 ? _bufferSize.value : 0,
      playbackDeviceId: devId,
    );

    if (pauseOnDeviceChange) {
      _backend.setPauseOnDeviceChange(true);
    }

    _audioDevice.setSnapshot(_backend.getCurrentDevice());

    action = PlayerAction(this);

    spatial = SpatialController(
      setEnabled: (enabled) {
        if (!_isDisposed) _backend.setSpatialEnabled(enabled);
      },
      setListener: (listener) {
        if (!_isDisposed) _backend.setSpatialListener(listener);
      },
      setEmitter: (emitter) {
        if (!_isDisposed) _backend.setSpatialEmitter(emitter);
      },
      setDopplerFactor: (factor) {
        if (!_isDisposed) _backend.setSpatialDopplerFactor(factor);
      },
      setSpeedOfSound: (speed) {
        if (!_isDisposed) _backend.setSpatialSpeedOfSound(speed);
      },
    );

    stream = PlayerStream(
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
      metaBytesController: _metaBytes.controller,
    );

    state = PlayerState(
      getPosition: () => _position.value,
      getDuration: () => _duration.value,
      getPlaying: () => _playing.value,
      getBuffering: () => _buffering.value,
      getCompleted: () => _completed.value,
      getOpening: () => _opening.value,
      getPlaybackState: () => _playbackState.value,
      getBufferedPosition: () => _bufferedPosition.value,
      getBufferedPercentage: () => _bufferedPercentage.value,
      getBufferedRange: () => _bufferedRange.value,
      getTrackMetadata: () => _trackMetadata.value,
      getVolume: () => _volume.value,
      getRate: () => _rate.value,
      getPitch: () => _pitch.value,
      getBufferSize: () => _bufferSize.value,
      getAudioBitrate: () => _audioBitrate.value,
      getEqualizer: () => _equalizer.value,
      getAudioDevice: getAudioDevice,
      getPauseOnDeviceChange: () => _pauseOnDeviceChange.value,
      getSkipSilence: () =>
          _silenceConfig.value.mode != SilenceSkipMode.disabled,
      getSilenceSkipMode: () => _silenceConfig.value.mode,
      getSilenceConfig: () => _silenceConfig.value,
      getSilenceSavedDuration: () => _silenceSavedDuration.value,
      getVisualizer: () => _visualizer.value,
      getVisualizerEnabled: () => _isVisualizerActive,
      getPreamp: () => _preamp.value,
      getReplayGain: () => _replayGain.value,
      getBalance: () => _balance.value,
      getMono: () => _mono.value,
      getCrossfeed: () => _crossfeed.value,
      getSpatializerEnabled: () => _spatializerEnabled.value,
      getSpatializerWidth: () => _spatializerWidth.value,
      getReverb: () => _reverb.value,
      getLimiterEnabled: () => _limiterEnabled.value,
      getMetaBytes: _getMetaBytes,
    );

    action.open(source);
  }

  /// Awaits completion of the initial audio source opening triggered by the constructor.
  Future<void> get waitUntilOpen => action.waitUntilOpen();

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  /// Returns the currently active audio output device.
  AudioDevice getAudioDevice() =>
      _isDisposed ? _audioDevice.value : _backend.getCurrentDevice();

  /// Updates pause on device change setting and propagates to native backend and stream.
  void setPauseOnDeviceChangeInternal(bool enabled) {
    if (_pauseOnDeviceChange.value == enabled) return;
    if (!_isDisposed) {
      _backend.setPauseOnDeviceChange(enabled);
    }
    _pauseOnDeviceChange.emitIfChanged(enabled);
  }

  /// Internal handle to the native miniaudio player.
  dynamic get handle => _backend.handle;

  /// Audio sampling rate in Hz of the currently active source (or engine default).
  int get sampleRate => _isDisposed ? 0 : _backend.sampleRate;

  /// Channel count of the currently active source (e.g. 1 for mono, 2 for stereo).
  int get channels => _isDisposed ? 0 : _backend.channels;

  /// Default ahead buffer window for local files.
  Duration get bufferLocalDuration => _globalConfig.bufferLocalDuration;

  /// Default ahead buffer window for progressive network audio.
  Duration get bufferNetworkDuration => _globalConfig.bufferNetworkDuration;

  /// Default ahead buffer window for continuous live streams.
  Duration get bufferLiveStreamDuration =>
      _globalConfig.bufferLiveStreamDuration;

  /// Default behind buffer window retained in circular RAM cache for local files.
  Duration get bufferBehindLocalDuration =>
      _globalConfig.bufferBehindLocalDuration;

  /// Default behind buffer window retained in circular RAM cache for network streams.
  Duration get bufferBehindNetworkDuration =>
      _globalConfig.bufferBehindNetworkDuration;

  /// Default behind buffer window retained in circular RAM cache for live streams.
  Duration get bufferBehindLiveStreamDuration =>
      _globalConfig.bufferBehindLiveStreamDuration;

  /// Returns the current number of bytes retained in the pinned Head cache.
  int get pinnedHeadSize => _isDisposed ? 0 : _backend.pinnedHeadSize;

  /// Ensures that the player has not been disposed.
  void ensureNotDisposed() {
    if (_isDisposed) {
      throw const MiniaudioPlayerException(
        'Player is already disposed',
        errorCode: MapResult.errorInvalidState,
      );
    }
  }

  void _updateNativeVisualizerState() {
    if (_isDisposed) return;
    final shouldEnable = _isVisualizerActive;
    _backend.setVisualizerEnabled(shouldEnable);
    if (!shouldEnable) {
      _visualizer.setSnapshot(VisualizerData.empty());
      if (_hasVisualizerListeners) {
        _visualizer.forceEmit(VisualizerData.empty());
      }
    }
  }

  /// Sets or clears the explicit manual visualizer override.
  void setManualVisualizerOverride(bool? override) {
    _manualVisualizerOverride = override;
    _updateNativeVisualizerState();
  }

  /// Sets whether the visualizer DSP is manually forced enabled or disabled.
  void setManualVisualizerEnabled(bool enabled) =>
      setManualVisualizerOverride(enabled);

  /// Synchronously transitions player into Opening state and flushes all stale telemetry.
  void notifyOpening() {
    if (_isDisposed) return;
    _opening.forceEmit(true);
    _playbackState.forceEmit(PlaybackState.opening);
    _playing.forceEmit(false);
    _buffering.forceEmit(false);
    _completed.forceEmit(false);
    _position.forceEmit(Duration.zero);
    _duration.forceEmit(Duration.zero);
    _bufferedPosition.forceEmit(Duration.zero);
    _bufferedPercentage.forceEmit(0.0);
    _bufferedRange.forceEmit(const BufferedRange());
    resetMetadata();
  }

  /// Notifies that opening completed successfully.
  void notifyOpenCompleted() {
    if (_isDisposed) return;
    _opening.forceEmit(false);
    if (_playbackState.value == PlaybackState.opening) {
      _playbackState.forceEmit(PlaybackState.stopped);
    }
    _getMetaBytes();
  }

  void notifyOpenComplete() => notifyOpenCompleted();

  /// Notifies that opening failed due to an error.
  void notifyOpenFailed([Object? error]) {
    if (_isDisposed) return;
    final errCode =
        (error is MiniaudioPlayerException && error.errorCode != null)
            ? error.errorCode!
            : MapResult.errorDecodeFailed;
    try {
      _backend.notifyOpenError(errCode);
    } catch (_) {}
    _opening.forceEmit(false);
    _playbackState.forceEmit(PlaybackState.error);
  }

  /// Notifies the player that playback was stopped manually.
  void notifyStopped() {
    if (_isDisposed) return;
    final wasPlaying = _playing.value;
    final wasCompleted = _completed.value;
    final wasOpening = _opening.value;

    _opening.setSnapshot(false);
    _playbackState.setSnapshot(PlaybackState.stopped);
    _playing.setSnapshot(false);
    _completed.setSnapshot(false);
    _position.setSnapshot(Duration.zero);
    _visualizer.setSnapshot(VisualizerData.empty());

    if (_isVisualizerActive) {
      _visualizer.forceEmit(VisualizerData.empty());
    }
    if (wasOpening) _opening.forceEmit(false);
    _playbackState.forceEmit(PlaybackState.stopped);
    if (wasPlaying) _playing.forceEmit(false);
    if (wasCompleted) _completed.forceEmit(false);
    _position.forceEmit(Duration.zero);
  }

  /// Updates buffering state and notifies listeners if changed.
  void notifyBuffering(bool isBuffering) {
    if (!_isDisposed) _buffering.emitIfChanged(isBuffering);
  }

  /// Explicitly resets cached metadata to null and emits null on the metadata stream.
  void resetMetadata() {
    _trackMetadata.forceEmit(null);
    _metaBytes.forceEmit(null);
  }

  Uint8List? _getMetaBytes() {
    if (_isDisposed) return null;
    final bytes = _backend.getMetaBytes();
    if (bytes != null) {
      _metaBytes.forceEmit(bytes);
    }
    return bytes;
  }

  /// Checks if native metadata has updated and updates cached copy if so.
  void checkMetaBytesUpdated() => _getMetaBytes();

  /// Ingests dynamic ICY livestream metadata received over network.
  void setIcyMeta(Uint8List data) => action.setIcyMeta(data);

  /// Probes tail metadata (ID3v1, APEv2, MP4 moov, etc.) directly into buffer Tail.
  void probeTail(Uint8List data, int tailOffset) =>
      action.probeTail(data, tailOffset);

  // =========================================================================
  // PlayerBackendListener Callbacks
  // =========================================================================

  @override
  void onState(PlaybackState newState) {
    if (_isDisposed) return;
    if (_playbackState.value == PlaybackState.error &&
        newState == PlaybackState.stopped) {
      return;
    }
    _opening.emitIfChanged(newState == PlaybackState.opening);

    if (newState == PlaybackState.stopped ||
        newState == PlaybackState.playing ||
        newState == PlaybackState.paused) {
      if (_completed.value) {
        _completed.emitIfChanged(false);
      }
    }
    if (newState == PlaybackState.stopped) {
      if (_playing.value) _playing.emitIfChanged(false);
      if (_position.value != Duration.zero) {
        _position.emitIfChanged(Duration.zero);
      }
    }
    _playbackState.emitIfChanged(newState);
  }

  @override
  void onPosition(Duration pos) {
    if (!_isDisposed) _position.emitIfChanged(pos);
  }

  @override
  void onDuration(Duration dur) {
    if (!_isDisposed) _duration.emitIfChanged(dur);
  }

  @override
  void onPlaying(bool isPlaying) {
    if (_isDisposed) return;
    if (_playing.value != isPlaying) {
      _playing.emitIfChanged(isPlaying);
      if (!isPlaying) {
        _visualizer.setSnapshot(VisualizerData.empty());
        if (_isVisualizerActive) {
          _visualizer.forceEmit(VisualizerData.empty());
        }
      }
    }
  }

  @override
  void onBuffering(bool isBuffering) => notifyBuffering(isBuffering);

  @override
  void onCompleted(bool isCompleted) {
    if (_isDisposed || _completed.value == isCompleted) return;
    _completed.emitIfChanged(isCompleted);
    if (isCompleted) {
      _playing.forceEmit(false);
      _playbackState.forceEmit(PlaybackState.completed);
      _position.forceEmit(_duration.value);
      _visualizer.setSnapshot(VisualizerData.empty());
      if (_isVisualizerActive) {
        _visualizer.forceEmit(VisualizerData.empty());
      }
    } else if (_playbackState.value == PlaybackState.completed) {
      _playbackState.forceEmit(PlaybackState.paused);
    }
  }

  @override
  void onVolume(double volume) => notifyVolumeChanged(volume);

  @override
  void onRate(double rate) => notifyRateChanged(rate);

  @override
  void onPitch(double pitch) => notifyPitchChanged(pitch);

  @override
  void onBitrate(int bitrate) {
    if (!_isDisposed) _audioBitrate.emitIfChanged(bitrate);
  }

  @override
  void onBufferSize(int bufferSize) => notifyBufferSizeChanged(bufferSize);

  @override
  void onSilenceSaved(Duration duration) {
    if (!_isDisposed) _silenceSavedDuration.emitIfChanged(duration);
  }

  @override
  void onSilenceConfig(SilenceSkipConfig config) =>
      notifySilenceConfigChanged(config);

  @override
  void onBufferedRange(BufferedRange br) {
    if (_isDisposed || _bufferedRange.value == br) return;
    _bufferedRange.forceEmit(br);
    _bufferedPosition.forceEmit(br.end);
    _bufferedPercentage.forceEmit(br.percentage);
  }

  @override
  void onVisualizer(VisualizerData data) {
    if (_isDisposed || !_isVisualizerActive) return;
    final frame = _playing.value ? data : VisualizerData.empty();
    _visualizer.forceEmit(frame);
  }

  @override
  void onVisualizerEnabled(bool enabled) =>
      notifyVisualizerEnabledChanged(enabled);

  @override
  void onDevice(AudioDevice device) => notifyDeviceChanged(device);

  @override
  void onTrackMetadata(AudioTrackMetadata? metadata) =>
      setTrackMetadata(metadata);

  @override
  void onEqualizer(Equalizer equalizer) => notifyEqualizerChanged(equalizer);

  @override
  void onPreamp(double preampDb) => notifyPreampChanged(preampDb);

  @override
  void onReplayGain(ReplayGainConfig config) => notifyReplayGainChanged(config);

  @override
  void onBalance(double balance) => notifyBalanceChanged(balance);

  @override
  void onMono(bool enabled) => notifyMonoChanged(enabled);

  @override
  void onCrossfeed(CrossfeedMode mode) => notifyCrossfeedChanged(mode);

  @override
  void onSpatializer({required bool enabled, required double width}) =>
      notifySpatializerChanged(enabled: enabled, width: width);

  @override
  void onReverb(Reverb reverb) => notifyReverbChanged(reverb);

  @override
  void onLimiter(bool enabled) => notifyLimiterChanged(enabled);

  @override
  void onError(String message, int errorCode) {
    if (!_isDisposed) _playbackState.emitIfChanged(PlaybackState.error);
  }

  // =========================================================================
  // Synchronous State Snapshot & Stream Notification Helpers
  // =========================================================================

  void setVolumeSnapshot(double volume) {
    if (!_isDisposed) _volume.setSnapshot(volume);
  }

  void setRateSnapshot(double rate) {
    if (!_isDisposed) _rate.setSnapshot(rate);
  }

  void setPitchSnapshot(double pitch) {
    if (!_isDisposed) _pitch.setSnapshot(pitch);
  }

  void setBufferSizeSnapshot(int bufferSize) {
    if (!_isDisposed) _bufferSize.setSnapshot(bufferSize);
  }

  void setEqualizerSnapshot(Equalizer equalizer) {
    if (!_isDisposed) _equalizer.setSnapshot(equalizer);
  }

  void setSilenceConfigSnapshot(SilenceSkipConfig config) {
    if (!_isDisposed) _silenceConfig.setSnapshot(config);
  }

  void setReplayGainSnapshot(ReplayGainConfig config) {
    if (!_isDisposed) _replayGain.setSnapshot(config);
  }

  void setPreampSnapshot(double preampDb) {
    if (!_isDisposed) _preamp.setSnapshot(preampDb);
  }

  void setBalanceSnapshot(double balance) {
    if (!_isDisposed) _balance.setSnapshot(balance);
  }

  void setMonoSnapshot(bool mono) {
    if (!_isDisposed) _mono.setSnapshot(mono);
  }

  void setCrossfeedSnapshot(CrossfeedMode crossfeed) {
    if (!_isDisposed) _crossfeed.setSnapshot(crossfeed);
  }

  void setSpatializerSnapshot({required bool enabled, required double width}) {
    if (_isDisposed) return;
    _spatializerEnabled.setSnapshot(enabled);
    _spatializerWidth.setSnapshot(width);
  }

  void setLimiterSnapshot(bool enabled) {
    if (!_isDisposed) _limiterEnabled.setSnapshot(enabled);
  }

  void setReverbSnapshot(Reverb reverb) {
    if (!_isDisposed) _reverb.setSnapshot(reverb);
  }

  void notifyVolumeChanged(double volume) {
    if (!_isDisposed) _volume.emitIfChanged(volume);
  }

  void notifyRateChanged(double rate) {
    if (!_isDisposed) _rate.emitIfChanged(rate);
  }

  void notifyPitchChanged(double pitch) {
    if (!_isDisposed) _pitch.emitIfChanged(pitch);
  }

  void notifyBufferSizeChanged(int bufferSize) {
    if (!_isDisposed) _bufferSize.emitIfChanged(bufferSize);
  }

  void notifyEqualizerChanged(Equalizer equalizer) {
    if (!_isDisposed) _equalizer.emitIfChanged(equalizer);
  }

  void notifyDeviceChanged(AudioDevice device) {
    if (!_isDisposed) _audioDevice.emitIfChanged(device);
  }

  void notifySilenceConfigChanged(SilenceSkipConfig config) {
    if (_isDisposed) return;
    _skipSilence.emitIfChanged(config.mode != SilenceSkipMode.disabled);
    _silenceConfig.emitIfChanged(config);
  }

  void notifyReplayGainChanged(ReplayGainConfig config) {
    if (!_isDisposed) _replayGain.emitIfChanged(config);
  }

  void notifyPreampChanged(double preampDb) {
    if (!_isDisposed) _preamp.emitIfChanged(preampDb);
  }

  void notifyBalanceChanged(double balance) {
    if (!_isDisposed) _balance.emitIfChanged(balance);
  }

  void notifyMonoChanged(bool mono) {
    if (!_isDisposed) _mono.emitIfChanged(mono);
  }

  void notifyCrossfeedChanged(CrossfeedMode crossfeed) {
    if (!_isDisposed) _crossfeed.emitIfChanged(crossfeed);
  }

  void notifySpatializerChanged({
    required bool enabled,
    required double width,
  }) {
    if (_isDisposed) return;
    _spatializerEnabled.emitIfChanged(enabled);
    _spatializerWidth.emitIfChanged(width);
  }

  void notifyLimiterChanged(bool enabled) {
    if (!_isDisposed) _limiterEnabled.emitIfChanged(enabled);
  }

  void notifyReverbChanged(Reverb reverb) {
    if (!_isDisposed) _reverb.emitIfChanged(reverb);
  }

  void notifyVisualizerEnabledChanged(bool enabled) {
    if (!_isDisposed) _visualizerEnabled.emitIfChanged(enabled);
  }

  /// Updates current track metadata and notifies listeners.
  void setTrackMetadata(AudioTrackMetadata? metadata) {
    if (!_isDisposed) _trackMetadata.emitIfChanged(metadata);
  }

  /// Destroys the player instance and frees audio engine resources.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    resetMetadata();
    action.dispose();
    await _backend.dispose();

    for (final prop in _allProperties) {
      await prop.close();
    }
  }
}
