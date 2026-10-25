import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/unified_audio_loader.dart';
import '../platform/platform_backend.dart';
import '../platform/platform_select.dart';
import '../reverb.dart';
import 'audio_analysis_result.dart';
import 'audio_device.dart';
import 'buffered_range.dart';
import 'dsp_config.dart';
import 'player_action.dart';
import 'player_exception.dart';
import 'player_state.dart';
import 'player_stream.dart';
import 'silence_skip_config.dart';
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
  /// Optional global loader for resolving Flutter assets (e.g. `(key) => (await rootBundle.load(key)).buffer.asUint8List()`).
  static AssetBytesLoader? assetLoader;

  /// Default period buffer size in frames applied when instantiating new players
  /// (0 = miniaudio device native default).
  int defaultBufferSize;

  /// Global log level controlling native and engine log output.
  MiniaudioLogLevel logLevel;

  /// Default audio output device applied when instantiating new players
  /// (default: [AudioDevice.auto]).
  AudioDevice defaultAudioDevice;

  /// Resolver function to format the user-friendly [AudioDevice.displayName]
  /// when an audio device is set to automatic/system default routing.
  ///
  /// Defaults to `"System Default ($resolvedName)"` (or `"System Default"` if empty).
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

/// Cross-platform, ultra-low-resource audio player for Flutter and Web.
///
/// Connects to the native C miniaudio engine on desktop/mobile and to
/// WebAssembly + AudioWorklet + Web Workers on web.
class MiniaudioPlayer implements PlayerBackendListener {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  /// Currently active global player configuration.
  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;

  /// Broadcast stream of system audio output device list changes.
  static Stream<List<AudioDevice>> getAudioDevicesStream() {
    return getPlatformService().getAudioDevicesStream();
  }

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
  }) {
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
  static Future<List<AudioDevice>> getAudioDevices() async {
    return getPlatformService().getAudioDevices();
  }

  /// Synchronous enumeration of all available playback audio devices on the system.
  static List<AudioDevice> getAudioDevicesSync() {
    return getPlatformService().getAudioDevicesSync();
  }

  /// Analyzes an audio file in a single, high-performance decoding pass.
  static Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    return getPlatformService().analyzeAudio(
      filePath,
      replayGain: replayGain,
      waveform: waveform,
      waveformPoints: waveformPoints,
      targetLufs: targetLufs,
    );
  }

  /// Synchronously analyzes an audio file in a single decoding pass.
  static AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    return getPlatformService().analyzeAudioSync(
      filePath,
      replayGain: replayGain,
      waveform: waveform,
      waveformPoints: waveformPoints,
      targetLufs: targetLufs,
    );
  }

  /// Analyzes audio directly from memory bytes.
  static Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    return getPlatformService().analyzeAudioMemory(
      bytes,
      replayGain: replayGain,
      waveform: waveform,
      waveformPoints: waveformPoints,
      targetLufs: targetLufs,
    );
  }

  late final PlayerBackend _backend;

  /// Internal platform backend instance.
  PlayerBackend get backend => _backend;

  // Stream controllers (broadcast)
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
  final StreamController<Uint8List?> _metaBytesController =
      StreamController<Uint8List?>.broadcast();

  // Cached synchronous state snapshot
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  bool _opening = false;
  PlaybackState _playbackState = PlaybackState.stopped;
  Duration _bufferedPosition = Duration.zero;
  double _bufferedPercentage = 0.0;
  BufferedRange _bufferedRange = const BufferedRange();
  AudioTrackMetadata? _trackMetadata;
  BufferedRange? _lastBufferedRange;
  AudioTrackMetadata? _lastTrackMetadata;
  double _volume = 1.0;
  double _lastEmittedVolume = 1.0;
  double _rate = 1.0;
  double _lastEmittedRate = 1.0;
  double _pitch = 1.0;
  double _lastEmittedPitch = 1.0;
  int _bufferSize = _globalConfig.defaultBufferSize;
  int _lastEmittedBufferSize = _globalConfig.defaultBufferSize;
  int _audioBitrate = 0;
  Equalizer _equalizer = Equalizer.flat;
  Equalizer _lastEmittedEqualizer = Equalizer.flat;
  AudioDevice _audioDevice = _globalConfig.defaultAudioDevice;
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();
  SilenceSkipConfig _lastEmittedSilenceConfig = const SilenceSkipConfig();
  Duration _silenceSavedDuration = Duration.zero;
  VisualizerData _visualizer = VisualizerData.empty();
  bool _visualizerEnabled = false;
  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;

  /// Returns whether the visualizer DSP is currently active.
  bool get _isVisualizerActive =>
      _manualVisualizerOverride ?? _hasVisualizerListeners;
  double _preamp = 0.0;
  double _lastEmittedPreamp = 0.0;
  ReplayGainConfig _replayGain = const ReplayGainConfig();
  ReplayGainConfig _lastEmittedReplayGain = const ReplayGainConfig();
  double _balance = 0.0;
  double _lastEmittedBalance = 0.0;
  bool _mono = false;
  bool _lastEmittedMono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  CrossfeedMode _lastEmittedCrossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  bool _lastEmittedSpatializerEnabled = false;
  double _spatializerWidth = 1.0;
  double _lastEmittedSpatializerWidth = 1.0;
  Reverb _reverb = Reverb.off;
  Reverb _lastEmittedReverb = Reverb.off;
  bool _limiterEnabled = true;
  bool _lastEmittedLimiterEnabled = true;

  bool _isDisposed = false;

  /// Broadcast stream of opening state (`true` while preparing audio source, `false` otherwise).
  Stream<bool> get opening => stream.opening;

  /// Broadcast stream of current playback lifecycle state.
  Stream<PlaybackState> get playbackState => stream.playbackState;

  /// Action interface for controlling playback, volume, rate, pitch, buffer size, and DSP.
  late final PlayerAction action;

  /// Reactive stream interface for observing state changes.
  late final PlayerStream stream;

  /// Synchronous state snapshot interface.
  late final PlayerState state;

  /// Active unified audio loader instance, if a source is loaded.
  UnifiedAudioLoader? get loader => action.activeLoader;

  /// Active unified audio loader instance (alias for [loader]).
  UnifiedAudioLoader? get streamer => action.activeLoader;

  /// Creates a [MiniaudioPlayer] instance initialized with
  /// [MiniaudioPlayerGlobalConfig.defaultBufferSize] and
  /// [MiniaudioPlayerGlobalConfig.defaultAudioDevice].
  MiniaudioPlayer({int? bufferSize, AudioDevice? defaultAudioDevice}) {
    _bufferSize = bufferSize ?? _globalConfig.defaultBufferSize;
    _audioDevice = defaultAudioDevice ?? _globalConfig.defaultAudioDevice;

    _visualizerController = StreamController<VisualizerData>.broadcast(
      onListen: () {
        _hasVisualizerListeners = true;
        _updateNativeVisualizerState();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _updateNativeVisualizerState();
      },
    );

    if (_globalConfig.logLevel.value > 0) {
      try {
        getPlatformService().setLogLevel(_globalConfig.logLevel.value);
      } catch (_) {}
    }

    _backend = createPlayerBackend(this);
    _backend.setListener(this);

    final devId = (_audioDevice.id.isNotEmpty && _audioDevice.id != 'auto')
        ? _audioDevice.id
        : null;

    _backend.init(
      sampleRate: 0,
      channels: 0,
      periodSize: _bufferSize > 0 ? _bufferSize : 0,
      playbackDeviceId: devId,
    );

    _audioDevice = _backend.getCurrentDevice();

    action = PlayerAction(this);

    stream = PlayerStream(
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
      metaBytesController: _metaBytesController,
    );

    state = PlayerState(
      getPosition: () => _position,
      getDuration: () => _duration,
      getPlaying: () => _playing,
      getBuffering: () => _buffering,
      getCompleted: () => _completed,
      getOpening: () => _opening,
      getPlaybackState: () => _playbackState,
      getBufferedPosition: () => _bufferedPosition,
      getBufferedPercentage: () => _bufferedPercentage,
      getBufferedRange: () => _bufferedRange,
      getTrackMetadata: () => _trackMetadata,
      getVolume: () => _volume,
      getRate: () => _rate,
      getPitch: () => _pitch,
      getBufferSize: () => _bufferSize,
      getAudioBitrate: () => _audioBitrate,
      getEqualizer: () => _equalizer,
      getAudioDevice: getAudioDevice,
      getSkipSilence: () => _silenceConfig.mode != SilenceSkipMode.disabled,
      getSilenceSkipMode: () => _silenceConfig.mode,
      getSilenceConfig: () => _silenceConfig,
      getSilenceSavedDuration: () => _silenceSavedDuration,
      getVisualizer: () => _visualizer,
      getVisualizerEnabled: () => _isVisualizerActive,
      getPreamp: () => _preamp,
      getReplayGain: () => _replayGain,
      getBalance: () => _balance,
      getMono: () => _mono,
      getCrossfeed: () => _crossfeed,
      getSpatializerEnabled: () => _spatializerEnabled,
      getSpatializerWidth: () => _spatializerWidth,
      getReverb: () => _reverb,
      getLimiterEnabled: () => _limiterEnabled,
      getMetaBytes: _getMetaBytes,
    );
  }

  /// Returns the currently active audio output device.
  AudioDevice getAudioDevice() {
    if (_isDisposed) {
      return _audioDevice;
    }
    return _backend.getCurrentDevice();
  }

  /// Internal handle to the native miniaudio player.
  dynamic get handle => _backend.handle;

  /// Audio sampling rate in Hz of the currently active source (or engine default).
  int get sampleRate {
    if (_isDisposed) return 0;
    return _backend.sampleRate;
  }

  /// Channel count of the currently active source (e.g. 1 for mono, 2 for stereo).
  int get channels {
    if (_isDisposed) return 0;
    return _backend.channels;
  }

  /// Default ahead buffer window for local files.
  Duration get bufferLocalDuration => _globalConfig.bufferLocalDuration;

  /// Default ahead buffer window for progressive network audio.
  Duration get bufferNetworkDuration => _globalConfig.bufferNetworkDuration;

  /// Default ahead buffer window for continuous live streams.
  Duration get bufferLiveStreamDuration => _globalConfig.bufferLiveStreamDuration;

  /// Default behind buffer window retained in circular RAM cache for local files.
  Duration get bufferBehindLocalDuration =>
      _globalConfig.bufferBehindLocalDuration;

  /// Default behind buffer window retained in circular RAM cache for network streams.
  Duration get bufferBehindNetworkDuration =>
      _globalConfig.bufferBehindNetworkDuration;

  /// Default behind buffer window retained in circular RAM cache for live streams.
  Duration get bufferBehindLiveStreamDuration =>
      _globalConfig.bufferBehindLiveStreamDuration;

  /// Ensures that the player has not been disposed.
  void ensureNotDisposed() {
    if (_isDisposed) {
      throw MiniaudioPlayerException(
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
      _visualizer = VisualizerData.empty();
      if (!_visualizerController.isClosed && _hasVisualizerListeners) {
        _visualizerController.add(VisualizerData.empty());
      }
    }
  }

  /// Sets or clears the explicit manual visualizer override.
  void setManualVisualizerOverride(bool? override) {
    _manualVisualizerOverride = override;
    _updateNativeVisualizerState();
  }

  /// Sets whether the visualizer DSP is manually forced enabled or disabled.
  void setManualVisualizerEnabled(bool enabled) {
    setManualVisualizerOverride(enabled);
  }

  /// Synchronously transitions player into Opening state and flushes all stale telemetry.
  void notifyOpening() {
    if (_isDisposed) return;
    _opening = true;
    _playbackState = PlaybackState.opening;
    _playing = false;
    _buffering = false;
    _completed = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _bufferedPosition = Duration.zero;
    _bufferedPercentage = 0.0;
    _bufferedRange = const BufferedRange();
    _lastBufferedRange = const BufferedRange();
    resetMetadata();

    if (!_openingController.isClosed) {
      _openingController.add(true);
    }
    if (!_playbackStateController.isClosed) {
      _playbackStateController.add(PlaybackState.opening);
    }
    if (!_playingController.isClosed) {
      _playingController.add(false);
    }
    if (!_bufferingController.isClosed) {
      _bufferingController.add(false);
    }
    if (!_completedController.isClosed) {
      _completedController.add(false);
    }
    if (!_positionController.isClosed) {
      _positionController.add(Duration.zero);
    }
    if (!_durationController.isClosed) {
      _durationController.add(Duration.zero);
    }
    if (!_bufferedPositionController.isClosed) {
      _bufferedPositionController.add(Duration.zero);
    }
    if (!_bufferedPercentageController.isClosed) {
      _bufferedPercentageController.add(0.0);
    }
    if (!_bufferedRangeController.isClosed) {
      _bufferedRangeController.add(const BufferedRange());
    }
    if (!_trackMetadataController.isClosed) {
      _trackMetadataController.add(null);
    }
  }

  /// Notifies that opening completed successfully.
  void notifyOpenCompleted() {
    if (_isDisposed) return;
    _opening = false;
    if (_playbackState == PlaybackState.opening) {
      _playbackState = PlaybackState.stopped;
    }
    if (!_openingController.isClosed) {
      _openingController.add(false);
    }
    if (!_playbackStateController.isClosed &&
        _playbackState == PlaybackState.stopped) {
      _playbackStateController.add(PlaybackState.stopped);
    }
    _getMetaBytes();
  }

  /// Updates buffering state and notifies listeners if changed.
  void notifyBuffering(bool isBuffering) {
    if (_isDisposed) return;
    if (_buffering != isBuffering) {
      _buffering = isBuffering;
      if (!_bufferingController.isClosed) {
        _bufferingController.add(isBuffering);
      }
    }
  }

  /// Explicitly resets cached metadata to null and emits null on the metadata stream.
  void resetMetadata() {
    _trackMetadata = null;
    _lastTrackMetadata = null;
    if (!_metaBytesController.isClosed) {
      _metaBytesController.add(null);
    }
    if (!_trackMetadataController.isClosed) {
      _trackMetadataController.add(null);
    }
  }

  /// Synthesizes or retrieves cached metadata container bytes.
  Uint8List? _getMetaBytes() {
    if (_isDisposed) return null;
    final bytes = _backend.getMetaBytes();
    if (bytes != null && !_metaBytesController.isClosed) {
      _metaBytesController.add(bytes);
    }
    return bytes;
  }

  /// Checks if native metadata has updated and updates cached copy if so.
  void checkMetaBytesUpdated() {
    _getMetaBytes();
  }

  /// Ingests dynamic ICY livestream metadata received over network.
  void setIcyMeta(Uint8List data) => action.setIcyMeta(data);

  /// Probes tail metadata (ID3v1, APEv2, MP4 moov, etc.) directly into buffer Tail.
  void probeTail(Uint8List data, int tailOffset) =>
      action.probeTail(data, tailOffset);

  /// Returns the current number of bytes retained in the pinned Head cache.
  int get pinnedHeadSize {
    if (_isDisposed) return 0;
    return _backend.pinnedHeadSize;
  }

  void notifyOpenComplete() => notifyOpenCompleted();

  /// Notifies that opening failed due to an error.
  void notifyOpenFailed([Object? error]) {
    if (_isDisposed) return;
    final int errCode = (error is MiniaudioPlayerException && error.errorCode != null)
        ? error.errorCode!
        : MapResult.errorDecodeFailed;
    try {
      _backend.notifyOpenError(errCode);
    } catch (_) {}
    _opening = false;
    _playbackState = PlaybackState.error;
    if (!_openingController.isClosed) {
      _openingController.add(false);
    }
    if (!_playbackStateController.isClosed) {
      _playbackStateController.add(PlaybackState.error);
    }
  }

  /// Notifies the player that playback was stopped manually.
  void notifyStopped() {
    if (_isDisposed) return;
    final wasPlaying = _playing;
    final wasCompleted = _completed;
    final wasOpening = _opening;
    _opening = false;
    _playbackState = PlaybackState.stopped;
    _playing = false;
    _completed = false;
    _position = Duration.zero;
    _visualizer = VisualizerData.empty();

    if (!_visualizerController.isClosed && _isVisualizerActive) {
      _visualizerController.add(VisualizerData.empty());
    }

    if (!_openingController.isClosed && wasOpening) {
      _openingController.add(false);
    }
    if (!_playbackStateController.isClosed) {
      _playbackStateController.add(PlaybackState.stopped);
    }
    if (!_playingController.isClosed && wasPlaying) {
      _playingController.add(false);
    }
    if (!_completedController.isClosed && wasCompleted) {
      _completedController.add(false);
    }
    if (!_positionController.isClosed) {
      _positionController.add(Duration.zero);
    }
  }

  // =========================================================================
  // PlayerBackendListener Callbacks
  // =========================================================================

  @override
  void onState(PlaybackState newState) {
    if (_isDisposed) return;
    if (_playbackState == PlaybackState.error &&
        newState == PlaybackState.stopped) {
      return;
    }
    final bool isOpening = newState == PlaybackState.opening;
    if (isOpening != _opening) {
      _opening = isOpening;
      if (!_openingController.isClosed) {
        _openingController.add(isOpening);
      }
    }
    if (newState == PlaybackState.stopped ||
        newState == PlaybackState.playing ||
        newState == PlaybackState.paused) {
      if (_completed) {
        _completed = false;
        if (!_completedController.isClosed) {
          _completedController.add(false);
        }
      }
    }
    if (newState == PlaybackState.stopped) {
      if (_playing) {
        _playing = false;
        if (!_playingController.isClosed) {
          _playingController.add(false);
        }
      }
      if (_position != Duration.zero) {
        _position = Duration.zero;
        if (!_positionController.isClosed) {
          _positionController.add(Duration.zero);
        }
      }
    }
    if (_playbackState != newState) {
      _playbackState = newState;
      if (!_playbackStateController.isClosed) {
        _playbackStateController.add(newState);
      }
    }
    action.activeLoader?.onEngineTelemetryTick();
  }

  @override
  void onPosition(Duration pos) {
    if (_isDisposed) return;
    if (_position != pos) {
      _position = pos;
      if (!_positionController.isClosed) {
        _positionController.add(pos);
      }
    }
    action.activeLoader?.onEngineTelemetryTick();
  }

  @override
  void onDuration(Duration dur) {
    if (_isDisposed) return;
    if (_duration != dur) {
      _duration = dur;
      if (!_durationController.isClosed) {
        _durationController.add(dur);
      }
    }
  }

  @override
  void onPlaying(bool isPlaying) {
    if (_isDisposed) return;
    if (_playing != isPlaying) {
      _playing = isPlaying;
      if (!_playingController.isClosed) {
        _playingController.add(isPlaying);
      }
      if (!isPlaying) {
        _visualizer = VisualizerData.empty();
        if (!_visualizerController.isClosed && _isVisualizerActive) {
          _visualizerController.add(VisualizerData.empty());
        }
      }
    }
  }

  @override
  void onBuffering(bool isBuffering) {
    notifyBuffering(isBuffering);
    action.activeLoader?.onEngineTelemetryTick();
  }

  @override
  void onCompleted(bool isCompleted) {
    if (_isDisposed) return;
    if (_completed != isCompleted) {
      _completed = isCompleted;
      if (!_completedController.isClosed) {
        _completedController.add(isCompleted);
      }
      if (isCompleted) {
        _playing = false;
        if (!_playingController.isClosed) {
          _playingController.add(false);
        }
        _playbackState = PlaybackState.completed;
        if (!_playbackStateController.isClosed) {
          _playbackStateController.add(PlaybackState.completed);
        }
        _position = _duration;
        if (!_positionController.isClosed) {
          _positionController.add(_duration);
        }
        _visualizer = VisualizerData.empty();
        if (!_visualizerController.isClosed && _isVisualizerActive) {
          _visualizerController.add(VisualizerData.empty());
        }
      } else if (_playbackState == PlaybackState.completed) {
        _playbackState = PlaybackState.paused;
        if (!_playbackStateController.isClosed) {
          _playbackStateController.add(PlaybackState.paused);
        }
      }
    }
  }

  @override
  void onVolume(double volume) {
    notifyVolumeChanged(volume);
  }

  @override
  void onRate(double rate) {
    notifyRateChanged(rate);
  }

  @override
  void onPitch(double pitch) {
    notifyPitchChanged(pitch);
  }

  @override
  void onBitrate(int bitrate) {
    if (_isDisposed) return;
    if (_audioBitrate != bitrate) {
      _audioBitrate = bitrate;
      if (!_audioBitrateController.isClosed) {
        _audioBitrateController.add(bitrate);
      }
    }
  }

  @override
  void onBufferSize(int bufferSize) {
    notifyBufferSizeChanged(bufferSize);
  }

  @override
  void onSilenceSaved(Duration duration) {
    if (_isDisposed) return;
    if (_silenceSavedDuration != duration) {
      _silenceSavedDuration = duration;
      if (!_silenceSavedDurationController.isClosed) {
        _silenceSavedDurationController.add(duration);
      }
    }
  }

  @override
  void onSilenceConfig(SilenceSkipConfig config) {
    notifySilenceConfigChanged(config);
  }

  @override
  void onBufferedRange(BufferedRange br) {
    if (_isDisposed) return;
    if (_lastBufferedRange != br) {
      _lastBufferedRange = br;
      _bufferedRange = br;
      _bufferedPosition = br.end;
      _bufferedPercentage = br.streamPercentage;
      if (!_bufferedRangeController.isClosed) {
        _bufferedRangeController.add(br);
      }
      if (!_bufferedPositionController.isClosed) {
        _bufferedPositionController.add(br.end);
      }
      if (!_bufferedPercentageController.isClosed) {
        _bufferedPercentageController.add(br.streamPercentage);
      }
    }
    action.activeLoader?.onEngineTelemetryTick();
  }

  @override
  void onVisualizer(VisualizerData data) {
    if (_isDisposed || !_isVisualizerActive) return;
    _visualizer = _playing ? data : VisualizerData.empty();
    if (!_visualizerController.isClosed) {
      _visualizerController.add(_visualizer);
    }
  }

  @override
  void onVisualizerEnabled(bool enabled) {
    notifyVisualizerEnabledChanged(enabled);
  }

  @override
  void onDevice(AudioDevice device) {
    notifyDeviceChanged(device);
  }

  @override
  void onTrackMetadata(AudioTrackMetadata? metadata) {
    setTrackMetadata(metadata);
  }

  @override
  void onEqualizer(Equalizer equalizer) {
    notifyEqualizerChanged(equalizer);
  }

  @override
  void onPreamp(double preampDb) {
    notifyPreampChanged(preampDb);
  }

  @override
  void onReplayGain(ReplayGainConfig config) {
    notifyReplayGainChanged(config);
  }

  @override
  void onBalance(double balance) {
    notifyBalanceChanged(balance);
  }

  @override
  void onMono(bool enabled) {
    notifyMonoChanged(enabled);
  }

  @override
  void onCrossfeed(CrossfeedMode mode) {
    notifyCrossfeedChanged(mode);
  }

  @override
  void onSpatializer({required bool enabled, required double width}) {
    notifySpatializerChanged(enabled: enabled, width: width);
  }

  @override
  void onReverb(Reverb reverb) {
    notifyReverbChanged(reverb);
  }

  @override
  void onLimiter(bool enabled) {
    notifyLimiterChanged(enabled);
  }

  @override
  void onError(String message, int errorCode) {
    if (_isDisposed) return;
    if (_playbackState != PlaybackState.error) {
      _playbackState = PlaybackState.error;
      if (!_playbackStateController.isClosed) {
        _playbackStateController.add(PlaybackState.error);
      }
    }
  }

  void setVolumeSnapshot(double volume) {
    if (_isDisposed) return;
    _volume = volume;
  }

  void setRateSnapshot(double rate) {
    if (_isDisposed) return;
    _rate = rate;
  }

  void setPitchSnapshot(double pitch) {
    if (_isDisposed) return;
    _pitch = pitch;
  }

  void setBufferSizeSnapshot(int bufferSize) {
    if (_isDisposed) return;
    _bufferSize = bufferSize;
  }

  void setEqualizerSnapshot(Equalizer equalizer) {
    if (_isDisposed) return;
    _equalizer = equalizer;
  }

  void setSilenceConfigSnapshot(SilenceSkipConfig config) {
    if (_isDisposed) return;
    _silenceConfig = config;
  }

  void setReplayGainSnapshot(ReplayGainConfig config) {
    if (_isDisposed) return;
    _replayGain = config;
  }

  void setPreampSnapshot(double preampDb) {
    if (_isDisposed) return;
    _preamp = preampDb;
  }

  void setBalanceSnapshot(double balance) {
    if (_isDisposed) return;
    _balance = balance;
  }

  void setMonoSnapshot(bool mono) {
    if (_isDisposed) return;
    _mono = mono;
  }

  void setCrossfeedSnapshot(CrossfeedMode crossfeed) {
    if (_isDisposed) return;
    _crossfeed = crossfeed;
  }

  void setSpatializerSnapshot({required bool enabled, required double width}) {
    if (_isDisposed) return;
    _spatializerEnabled = enabled;
    _spatializerWidth = width;
  }

  void setLimiterSnapshot(bool enabled) {
    if (_isDisposed) return;
    _limiterEnabled = enabled;
  }

  void setReverbSnapshot(Reverb reverb) {
    if (_isDisposed) return;
    _reverb = reverb;
  }

  void notifyVolumeChanged(double volume) {
    if (_isDisposed) return;
    _volume = volume;
    if (_lastEmittedVolume == volume) return;
    _lastEmittedVolume = volume;
    if (!_volumeController.isClosed) {
      _volumeController.add(volume);
    }
  }

  void notifyRateChanged(double rate) {
    if (_isDisposed) return;
    _rate = rate;
    if (_lastEmittedRate == rate) return;
    _lastEmittedRate = rate;
    if (!_rateController.isClosed) {
      _rateController.add(rate);
    }
  }

  void notifyPitchChanged(double pitch) {
    if (_isDisposed) return;
    _pitch = pitch;
    if (_lastEmittedPitch == pitch) return;
    _lastEmittedPitch = pitch;
    if (!_pitchController.isClosed) {
      _pitchController.add(pitch);
    }
  }

  void notifyBufferSizeChanged(int bufferSize) {
    if (_isDisposed) return;
    _bufferSize = bufferSize;
    if (_lastEmittedBufferSize == bufferSize) return;
    _lastEmittedBufferSize = bufferSize;
    if (!_bufferSizeController.isClosed) {
      _bufferSizeController.add(bufferSize);
    }
  }

  void notifyEqualizerChanged(Equalizer equalizer) {
    if (_isDisposed) return;
    _equalizer = equalizer;
    if (_lastEmittedEqualizer == equalizer) return;
    _lastEmittedEqualizer = equalizer;
    if (!_equalizerController.isClosed) {
      _equalizerController.add(equalizer);
    }
  }

  void notifyDeviceChanged(AudioDevice device) {
    if (_isDisposed) return;
    if (_audioDevice == device) return;
    _audioDevice = device;
    if (!_audioDeviceController.isClosed) {
      _audioDeviceController.add(device);
    }
  }

  void notifySilenceConfigChanged(SilenceSkipConfig config) {
    if (_isDisposed) return;
    _silenceConfig = config;
    if (_lastEmittedSilenceConfig == config) return;
    final wasEnabled =
        _lastEmittedSilenceConfig.mode != SilenceSkipMode.disabled;
    final isEnabled = config.mode != SilenceSkipMode.disabled;
    _lastEmittedSilenceConfig = config;

    if (wasEnabled != isEnabled && !_skipSilenceController.isClosed) {
      _skipSilenceController.add(isEnabled);
    }
    if (!_silenceConfigController.isClosed) {
      _silenceConfigController.add(config);
    }
  }

  void notifyReplayGainChanged(ReplayGainConfig config) {
    if (_isDisposed) return;
    _replayGain = config;
    if (_lastEmittedReplayGain == config) return;
    _lastEmittedReplayGain = config;
    if (!_replayGainController.isClosed) {
      _replayGainController.add(config);
    }
  }

  void notifyPreampChanged(double preampDb) {
    if (_isDisposed) return;
    _preamp = preampDb;
    if (_lastEmittedPreamp == preampDb) return;
    _lastEmittedPreamp = preampDb;
    if (!_preampController.isClosed) {
      _preampController.add(preampDb);
    }
  }

  void notifyBalanceChanged(double balance) {
    if (_isDisposed) return;
    _balance = balance;
    if (_lastEmittedBalance == balance) return;
    _lastEmittedBalance = balance;
    if (!_balanceController.isClosed) {
      _balanceController.add(balance);
    }
  }

  void notifyMonoChanged(bool mono) {
    if (_isDisposed) return;
    _mono = mono;
    if (_lastEmittedMono == mono) return;
    _lastEmittedMono = mono;
    if (!_monoController.isClosed) {
      _monoController.add(mono);
    }
  }

  void notifyCrossfeedChanged(CrossfeedMode crossfeed) {
    if (_isDisposed) return;
    _crossfeed = crossfeed;
    if (_lastEmittedCrossfeed == crossfeed) return;
    _lastEmittedCrossfeed = crossfeed;
    if (!_crossfeedController.isClosed) {
      _crossfeedController.add(crossfeed);
    }
  }

  void notifySpatializerChanged({required bool enabled, required double width}) {
    if (_isDisposed) return;
    _spatializerEnabled = enabled;
    _spatializerWidth = width;
    if (_lastEmittedSpatializerEnabled != enabled) {
      _lastEmittedSpatializerEnabled = enabled;
      if (!_spatializerEnabledController.isClosed) {
        _spatializerEnabledController.add(enabled);
      }
    }
    if (_lastEmittedSpatializerWidth != width) {
      _lastEmittedSpatializerWidth = width;
      if (!_spatializerWidthController.isClosed) {
        _spatializerWidthController.add(width);
      }
    }
  }

  void notifyLimiterChanged(bool enabled) {
    if (_isDisposed) return;
    _limiterEnabled = enabled;
    if (_lastEmittedLimiterEnabled == enabled) return;
    _lastEmittedLimiterEnabled = enabled;
    if (!_limiterEnabledController.isClosed) {
      _limiterEnabledController.add(enabled);
    }
  }

  void notifyReverbChanged(Reverb reverb) {
    if (_isDisposed) return;
    _reverb = reverb;
    if (_lastEmittedReverb == reverb) return;
    _lastEmittedReverb = reverb;
    if (!_reverbController.isClosed) {
      _reverbController.add(reverb);
    }
  }

  void notifyVisualizerEnabledChanged(bool enabled) {
    if (_isDisposed) return;
    if (_visualizerEnabled == enabled) return;
    _visualizerEnabled = enabled;
    if (!_visualizerEnabledController.isClosed) {
      _visualizerEnabledController.add(enabled);
    }
  }

  /// Sets the active audio output device.
  Future<void> setDevice(AudioDevice device) => action.setDevice(device);

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  /// Current internal buffer size in frames (0 = native default).
  int get bufferSize => _bufferSize;

  /// Current audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  int get audioBitrate => _audioBitrate;

  /// Alias for [audioBitrate].
  int get bitrate => _audioBitrate;

  /// Furthest continuous timestamp preloaded in RAM buffer.
  Duration get bufferedPosition => _bufferedPosition;

  /// Fraction (0.0 to 1.0) of the total track loaded into the buffer (for preloaded bar).
  double get bufferedPercentage => _bufferedPercentage;

  /// Comprehensive sliding-window circular buffer telemetry metrics.
  BufferedRange get bufferedRange => _bufferedRange;

  /// Current audio track metadata, or `null` if no track is opened.
  AudioTrackMetadata? get trackMetadata => _trackMetadata;

  /// Updates current track metadata and notifies listeners.
  void setTrackMetadata(AudioTrackMetadata? metadata) {
    if (_isDisposed) return;
    _trackMetadata = metadata;
    if (_lastTrackMetadata != metadata) {
      _lastTrackMetadata = metadata;
      if (!_trackMetadataController.isClosed) {
        _trackMetadataController.add(metadata);
      }
    }
  }

  /// Destroys the player instance and frees audio engine resources.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    resetMetadata();

    action.dispose();
    await _backend.dispose();

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
    await _metaBytesController.close();
  }
}
