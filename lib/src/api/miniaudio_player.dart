import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/custom_byte_provider.dart';
import '../platform/platform_backend.dart';
import '../platform/platform_select.dart';
import '../reverb.dart';
import 'audio_analysis_result.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'dsp_config.dart';
import 'logger.dart';
import 'player_exception.dart';
import 'player_state.dart';
import 'player_stream.dart';
import 'silence_skip_config.dart';
import 'spatial.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';

part 'player_action.dart';

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

/// Log verbosity levels for native miniaudio and sonic engine diagnostics.
enum MiniaudioLogLevel {
  /// Disables all native logging output (`0`).
  none(0),

  /// Alias for [none] (`0`).
  off(0),

  /// Logs only unrecoverable or critical native errors (`1`).
  error(1),

  /// Logs errors and non-fatal warnings (`2`).
  warning(2),

  /// Alias for [warning] (`2`).
  warn(2),

  /// Logs high-level lifecycle events (device init, open, seek, stop) (`3`).
  info(3),

  /// Logs verbose frame-level, buffer, and streaming diagnostics (`4`).
  debug(4),

  /// Logs maximum trace-level diagnostics (`5`).
  verbose(5);

  /// Integer representation passed to native C/WASM engine.
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

/// Global configuration parameters for all [MiniaudioPlayer] instances.
class MiniaudioPlayerGlobalConfig {
  /// Optional callback to receive structured diagnostic log messages.
  static MiniaudioLogCallback? onLog;

  /// Optional custom loader callback for resolving Flutter assets (e.g. `rootBundle.load`).
  static AssetBytesLoader? assetLoader;

  /// Default output period buffer size in frames (`0` = native default, `~2048` frames).
  int defaultBufferSize;

  /// Verbosity level for native C/WASM diagnostic logs (default: [MiniaudioLogLevel.none]).
  MiniaudioLogLevel logLevel;

  /// Default audio output device (`AudioDevice.auto` = system default).
  AudioDevice defaultAudioDevice;

  /// Resolver function to format the user-friendly [AudioDevice.displayName]
  /// when an audio device is set to automatic/system default routing.
  DefaultDeviceDisplayNameResolver defaultDeviceDisplayNameResolver;

  /// Target duration of audio to buffer ahead for local files (default: `30s`).
  Duration bufferLocalDuration;

  /// Target duration of audio to buffer ahead for HTTP/HTTPS progressive streams (default: `30s`).
  Duration bufferNetworkDuration;

  /// Target duration of audio to buffer ahead for live streams (default: `15s`).
  Duration bufferLiveStreamDuration;

  /// Duration of already-played audio retained in the circular buffer for instant
  /// backward seeking on local files (default: `10s`).
  Duration bufferBehindLocalDuration;

  /// Duration of already-played audio retained in the circular buffer for instant
  /// backward seeking on network streams (default: `15s`).
  Duration bufferBehindNetworkDuration;

  /// Duration of already-played audio retained in the circular buffer for live streams (default: `5s`).
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

/// Encapsulates a synchronous state value paired with a broadcast [StreamController].
class _ReactiveProperty<T> {
  T value;
  final StreamController<T> controller;

  _ReactiveProperty(
    this.value, {
    void Function()? onListen,
    void Function()? onCancel,
  }) : controller = StreamController<T>.broadcast(
          onListen: onListen,
          onCancel: onCancel,
        );

  void setSnapshot(T nextValue) {
    value = nextValue;
  }

  void emitIfChanged(T nextValue) {
    if (value != nextValue) {
      value = nextValue;
      if (!controller.isClosed) {
        controller.add(nextValue);
      }
    }
  }

  void forceEmit(T nextValue) {
    value = nextValue;
    if (!controller.isClosed) {
      controller.add(nextValue);
    }
  }

  Future<void> close() => controller.close();
}

/// Private telemetry listener routing backend callbacks into [MiniaudioPlayer] state.
final class _PlayerTelemetryListener implements PlayerBackendListener {
  final MiniaudioPlayer _player;

  const _PlayerTelemetryListener(this._player);

  @override
  void onState(PlaybackState newState) {
    MapLogger.info('Telemetry state -> $newState');
    _player._onState(newState);
  }

  @override
  void onPosition(Duration position) {
    MapLogger.verbose('Telemetry position -> ${position.inMilliseconds}ms');
    _player._onPosition(position);
  }

  @override
  void onDuration(Duration duration) {
    MapLogger.info('Telemetry duration -> ${duration.inMilliseconds}ms');
    _player._onDuration(duration);
  }

  @override
  void onPlaying(bool isPlaying) {
    MapLogger.info('Telemetry isPlaying -> $isPlaying');
    _player._onPlaying(isPlaying);
  }

  @override
  void onBuffering(bool isBuffering) {
    MapLogger.debug('Telemetry isBuffering -> $isBuffering');
    _player._onBuffering(isBuffering);
  }

  @override
  void onCompleted(bool isCompleted) {
    MapLogger.info('Telemetry isCompleted -> $isCompleted');
    _player._onCompleted(isCompleted);
  }

  @override
  void onVolume(double volume) {
    MapLogger.debug('Telemetry volume -> $volume');
    _player._volume.emitIfChanged(volume);
  }

  @override
  void onRate(double rate) {
    MapLogger.debug('Telemetry rate -> $rate');
    _player._rate.emitIfChanged(rate);
  }

  @override
  void onPitch(double pitch) {
    MapLogger.debug('Telemetry pitch -> $pitch');
    _player._pitch.emitIfChanged(pitch);
  }

  @override
  void onBitrate(int bitrate) {
    MapLogger.debug('Telemetry bitrate -> $bitrate bps');
    _player._audioBitrate.emitIfChanged(bitrate);
  }

  @override
  void onBufferSize(int bufferSize) {
    MapLogger.debug('Telemetry bufferSize -> $bufferSize frames');
    _player._bufferSize.emitIfChanged(bufferSize);
  }

  @override
  void onSilenceSaved(Duration duration) {
    MapLogger.debug('Telemetry silenceSaved -> ${duration.inMilliseconds}ms');
    _player._silenceSavedDuration.emitIfChanged(duration);
  }

  @override
  void onSilenceConfig(SilenceSkipConfig config) {
    MapLogger.debug('Telemetry silenceConfig -> mode: ${config.mode}, threshold: ${config.thresholdDb}dB');
    _player._onSilenceConfig(config);
  }

  @override
  void onBufferedRange(BufferedRange range) {
    MapLogger.verbose(
      'Telemetry bufferedRange -> fill: ${(range.fillPercentage * 100).toStringAsFixed(1)}%, '
      'stream: ${(range.percentage * 100).toStringAsFixed(1)}%, '
      'range: [${range.start.inMilliseconds}ms..${range.end.inMilliseconds}ms]',
    );
    _player._onBufferedRange(range);
  }

  @override
  void onVisualizer(VisualizerData data) {
    MapLogger.verbose(
      'Telemetry visualizer -> rms: ${data.rms.toStringAsFixed(4)}, peak: ${data.peak.toStringAsFixed(4)}',
    );
    _player._onVisualizer(data);
  }

  @override
  void onVisualizerEnabled(bool enabled) {
    MapLogger.debug('Telemetry visualizerEnabled -> $enabled');
    _player._visualizerEnabled.emitIfChanged(enabled);
  }

  @override
  void onDevice(AudioDevice device) {
    MapLogger.info('Telemetry device -> id: ${device.id}, name: ${device.name}');
    _player._audioDevice.emitIfChanged(device);
  }

  @override
  void onTrackMetadata(AudioTrackMetadata? metadata) {
    MapLogger.info(
      'Telemetry metadata -> format: ${metadata?.formatName}, codec: ${metadata?.codec.name}, duration: ${metadata?.duration.inMilliseconds}ms',
    );
    _player._trackMetadata.emitIfChanged(metadata);
  }

  @override
  void onEqualizer(Equalizer equalizer) {
    MapLogger.debug('Telemetry equalizer -> updated');
    _player._equalizer.emitIfChanged(equalizer);
  }

  @override
  void onPreamp(double preampDb) {
    MapLogger.debug('Telemetry preamp -> ${preampDb.toStringAsFixed(2)}dB');
    _player._preamp.emitIfChanged(preampDb);
  }

  @override
  void onReplayGain(ReplayGainConfig config) {
    MapLogger.debug(
      'Telemetry replayGain -> enabled: ${config.enabled}, gain: ${config.gainDb}dB',
    );
    _player._replayGain.emitIfChanged(config);
  }

  @override
  void onBalance(double balance) {
    MapLogger.debug('Telemetry balance -> $balance');
    _player._balance.emitIfChanged(balance);
  }

  @override
  void onMono(bool enabled) {
    MapLogger.debug('Telemetry mono -> $enabled');
    _player._mono.emitIfChanged(enabled);
  }

  @override
  void onCrossfeed(CrossfeedMode mode) {
    MapLogger.debug('Telemetry crossfeed -> $mode');
    _player._crossfeed.emitIfChanged(mode);
  }

  @override
  void onSpatializer({required bool enabled, required double width}) {
    MapLogger.debug('Telemetry spatializer -> enabled: $enabled, width: $width');
    _player._spatializerEnabled.emitIfChanged(enabled);
    _player._spatializerWidth.emitIfChanged(width);
  }

  @override
  void onReverb(Reverb reverb) {
    MapLogger.debug('Telemetry reverb -> enabled: ${reverb.enabled}, roomSize: ${reverb.roomSize}');
    _player._reverb.emitIfChanged(reverb);
  }

  @override
  void onLimiter(bool enabled) {
    MapLogger.debug('Telemetry limiter -> $enabled');
    _player._limiterEnabled.emitIfChanged(enabled);
  }

  @override
  void onError(String message, int errorCode) {
    MapLogger.error('Telemetry native error: [$errorCode] $message');
    _player._playbackState.emitIfChanged(PlaybackState.error);
  }
}

/// Ultra-low-resource cross-platform audio player using Rust Symphonia and miniaudio.
///
/// Features an event-driven architecture organized into 3 clean namespaces:
/// - `player.action` : Asynchronous methods to control playback, seeking, volume, rate, pitch, and DSP.
/// - `player.stream` : Reactive broadcast streams for UI bindings.
/// - `player.state`  : Synchronous getters for instant state inspection.
class MiniaudioPlayer {
  static MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  /// Current global configuration applied to newly created players.
  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;

  /// Reactive broadcast stream of available audio output devices on the system.
  static Stream<List<AudioDevice>> get audioDevicesStream =>
      getPlatformService().getAudioDevicesStream();

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

  /// Alias for [config].
  static MiniaudioPlayerGlobalConfig configure({
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
  }) =>
      config(
        defaultBufferSize: defaultBufferSize,
        logLevel: logLevel,
        defaultAudioDevice: defaultAudioDevice,
        defaultDeviceDisplayNameResolver: defaultDeviceDisplayNameResolver,
        bufferLocalDuration: bufferLocalDuration,
        bufferNetworkDuration: bufferNetworkDuration,
        bufferLiveStreamDuration: bufferLiveStreamDuration,
        bufferBehindLocalDuration: bufferBehindLocalDuration,
        bufferBehindNetworkDuration: bufferBehindNetworkDuration,
        bufferBehindLiveStreamDuration: bufferBehindLiveStreamDuration,
        assetLoader: assetLoader,
      );

  /// Resets global configuration to factory defaults.
  static void resetGlobalConfig() {
    _globalConfig = MiniaudioPlayerGlobalConfig();
    MiniaudioPlayerGlobalConfig.assetLoader = null;
    MiniaudioPlayerGlobalConfig.onLog = null;
  }

  /// Registers a custom asset loader function (e.g. `(key) async => (await rootBundle.load(key)).buffer.asUint8List()`).
  static void registerAssetLoader(
    Future<Uint8List> Function(String assetKey) loader,
  ) {
    MiniaudioPlayerGlobalConfig.assetLoader = loader;
  }

  /// Enumerates all available audio playback devices on the system.
  static Future<List<AudioDevice>> getAudioDevices() =>
      getPlatformService().getAudioDevices();

  /// Synchronously enumerates all available audio playback devices on the system.
  static List<AudioDevice> getAudioDevicesSync() =>
      getPlatformService().getAudioDevicesSync();

  /// Enumerates all available audio capture (microphone / line-in) devices on the system.
  static Future<List<AudioDevice>> getCaptureDevices() =>
      getPlatformService().getCaptureDevices();

  /// Synchronously enumerates all available audio capture devices on the system.
  static List<AudioDevice> getCaptureDevicesSync() =>
      getPlatformService().getCaptureDevicesSync();

  /// Performs a fast, offline acoustic scan of an audio file on a background isolate.
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

  /// Performs a synchronous offline acoustic scan of an audio file on the calling thread.
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

  /// Performs an offline acoustic scan of an audio buffer in memory.
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

  // Private reactive state properties
  final _position = _ReactiveProperty<Duration>(Duration.zero);
  final _duration = _ReactiveProperty<Duration>(Duration.zero);
  final _playing = _ReactiveProperty<bool>(false);
  final _buffering = _ReactiveProperty<bool>(false);
  final _completed = _ReactiveProperty<bool>(false);
  final _opening = _ReactiveProperty<bool>(false);
  final _playbackState =
      _ReactiveProperty<PlaybackState>(PlaybackState.stopped);
  final _bufferedPosition = _ReactiveProperty<Duration>(Duration.zero);
  final _bufferedPercentage = _ReactiveProperty<double>(0.0);
  final _bufferedRange =
      _ReactiveProperty<BufferedRange>(const BufferedRange());
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

    try {
      getPlatformService().setLogLevel(_globalConfig.logLevel.value);
    } catch (_) {}

    MapLogger.info(
      'Initializing MiniaudioPlayer (bufferSize: ${_bufferSize.value}, '
      'device: ${_audioDevice.value.id}, source: $source)',
    );

    _backend = createPlayerBackend();
    _backend.setListener(_PlayerTelemetryListener(this));

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

    action = PlayerAction._(this);

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

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw const MiniaudioPlayerException(
        'Player is already disposed',
        errorCode: MapResult.errorInvalidState,
      );
    }
  }

  void _setPauseOnDeviceChange(bool enabled) {
    if (_pauseOnDeviceChange.value == enabled) return;
    if (!_isDisposed) {
      _backend.setPauseOnDeviceChange(enabled);
    }
    _pauseOnDeviceChange.emitIfChanged(enabled);
  }

  void _updateNativeVisualizerState() {
    if (_isDisposed) return;
    final shouldEnable = _isVisualizerActive;
    _visualizerEnabled.emitIfChanged(shouldEnable);
    _backend.setVisualizerEnabled(shouldEnable);
    if (!shouldEnable) {
      _visualizer.setSnapshot(VisualizerData.empty());
      if (_hasVisualizerListeners) {
        _visualizer.forceEmit(VisualizerData.empty());
      }
    }
  }

  void _setManualVisualizerOverride(bool? override) {
    _manualVisualizerOverride = override;
    _updateNativeVisualizerState();
  }

  void _notifyOpening() {
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
    _resetMetadata();
  }

  void _notifyOpenCompleted() {
    if (_isDisposed) return;
    _opening.forceEmit(false);
    if (_playbackState.value == PlaybackState.opening) {
      _playbackState.forceEmit(PlaybackState.stopped);
    }
    _getMetaBytes();
  }

  void _notifyOpenFailed() {
    if (_isDisposed) return;
    _opening.forceEmit(false);
    _playbackState.forceEmit(PlaybackState.error);
  }

  void _notifyStopped() {
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

  void _resetMetadata() {
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

  void _onState(PlaybackState newState) {
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

  static bool _bytesEqual(Uint8List? a, Uint8List? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null || a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  void _onPosition(Duration pos) {
    if (_isDisposed) return;
    _position.emitIfChanged(pos);
    if (_trackMetadata.value?.isLiveStream == true ||
        _duration.value == Duration.zero) {
      final nextMeta = _backend.getMetaBytes();
      if (nextMeta != null &&
          nextMeta.isNotEmpty &&
          !_bytesEqual(_metaBytes.value, nextMeta)) {
        _metaBytes.forceEmit(nextMeta);
      }
    }
  }

  void _onDuration(Duration dur) {
    if (!_isDisposed) _duration.emitIfChanged(dur);
  }

  void _onPlaying(bool isPlaying) {
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

  void _onBuffering(bool isBuffering) {
    if (!_isDisposed) _buffering.emitIfChanged(isBuffering);
  }

  void _onCompleted(bool isCompleted) {
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

  void _onSilenceConfig(SilenceSkipConfig config) {
    if (_isDisposed) return;
    _skipSilence.emitIfChanged(config.mode != SilenceSkipMode.disabled);
    _silenceConfig.emitIfChanged(config);
  }

  void _onBufferedRange(BufferedRange br) {
    if (_isDisposed || _bufferedRange.value == br) return;
    _bufferedRange.forceEmit(br);
    _bufferedPosition.forceEmit(br.end);
    _bufferedPercentage.forceEmit(br.percentage);
  }

  void _onVisualizer(VisualizerData data) {
    if (_isDisposed || !_isVisualizerActive) return;
    final frame = _playing.value ? data : VisualizerData.empty();
    _visualizer.forceEmit(frame);
  }

  /// Destroys the player instance and frees audio engine resources.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    MapLogger.info('Disposing MiniaudioPlayer instance');

    _resetMetadata();
    action._dispose();
    await _backend.dispose();

    for (final prop in _allProperties) {
      await prop.close();
    }
  }
}
