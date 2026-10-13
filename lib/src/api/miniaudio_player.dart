import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../equalizer.dart';
import '../ffi/native_types.dart';
import 'audio_device.dart';
import 'player_action.dart';
import 'player_exception.dart';
import 'player_state.dart';
import 'player_stream.dart';
import 'audio_analysis_result.dart';
import 'dsp_config.dart';
import 'silence_skip_config.dart';
import 'visualizer_data.dart';
import '../reverb.dart';

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

/// Global configuration container for [MiniaudioPlayer].
class MiniaudioPlayerGlobalConfig {
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

  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
    this.defaultAudioDevice = AudioDevice.auto,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
  }) : defaultDeviceDisplayNameResolver = defaultDeviceDisplayNameResolver ??
            _defaultDeviceDisplayNameResolver;

  static String _defaultDeviceDisplayNameResolver(String resolvedName) {
    final clean = resolvedName.trim();
    return clean.isEmpty ? 'System Default' : 'System Default ($clean)';
  }
}

/// Cross-platform, ultra-low-resource audio player for Flutter.
///
/// Directly connects to the native C miniaudio engine without Dart Isolates,
/// utilizing native audio threads for real-time decoding, DSP, and playback.
class MiniaudioPlayer implements Finalizable {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  static final StreamController<List<AudioDevice>> _audioDevicesController =
      StreamController<List<AudioDevice>>.broadcast(
    onListen: () {
      _ensureDeviceNotificationListener();
    },
    onCancel: () {
      _removeDeviceNotificationListener();
    },
  );

  static List<AudioDevice> _cachedAudioDevices = const <AudioDevice>[
    AudioDevice.auto,
  ];

  static NativeCallable<native.miniaudio_player_device_notification_cbFunction>?
      _deviceNotificationCallable;

  static void _ensureDeviceNotificationListener() {
    if (_deviceNotificationCallable != null) return;
    try {
      _deviceNotificationCallable = NativeCallable<
          native.miniaudio_player_device_notification_cbFunction>.listener(
        _onNativeDeviceNotification,
      );
      native.miniaudio_player_set_device_notification_callback(
        _deviceNotificationCallable!.nativeFunction,
        nullptr,
      );
    } catch (_) {
      // Ignored if native library cannot be loaded or in mock/test environment
    }
  }

  static void _removeDeviceNotificationListener() {
    if (_deviceNotificationCallable == null) return;
    try {
      native.miniaudio_player_set_device_notification_callback(
        nullptr,
        nullptr,
      );
      _deviceNotificationCallable?.close();
      _deviceNotificationCallable = null;
    } catch (_) {
      // Ignored if native library cannot be loaded or in mock/test environment
    }
  }

  static void _onNativeDeviceNotification(Pointer<Void> userData) {
    try {
      _queryAudioDevices();
    } catch (_) {}
  }

  static void _updateAudioDevices(List<AudioDevice> devices) {
    _cachedAudioDevices = List.unmodifiable(devices);
    if (!_audioDevicesController.isClosed) {
      _audioDevicesController.add(_cachedAudioDevices);
    }
  }

  /// Broadcast stream of system audio output device list changes triggered by native C events.
  static Stream<List<AudioDevice>> getAudioDevicesStream() {
    return _audioDevicesController.stream;
  }

  /// Global configuration accessor and updater for [MiniaudioPlayer].
  static MiniaudioPlayerGlobalConfig config({
    int? defaultBufferSize,
    MiniaudioLogLevel? logLevel,
    AudioDevice? defaultAudioDevice,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
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
        native.miniaudio_player_set_log_level(logLevel.value);
      } catch (_) {
        // Ignored if native library cannot be loaded immediately in current environment
      }
    }
    if (defaultAudioDevice != null) {
      _globalConfig.defaultAudioDevice = defaultAudioDevice;
    }
    if (defaultDeviceDisplayNameResolver != null) {
      _globalConfig.defaultDeviceDisplayNameResolver =
          defaultDeviceDisplayNameResolver;
    }
    return _globalConfig;
  }

  /// Enumerates all available native playback audio devices on the system via FFI.
  ///
  /// The first item in the list is always the automatic/system-managed default device
  /// ([AudioDevice.auto]) with its [AudioDevice.resolvedName] populated.
  static Future<List<AudioDevice>> getAudioDevices() async {
    return _queryAudioDevices();
  }

  /// Synchronous enumeration of all available native playback audio devices on the system via FFI.
  static List<AudioDevice> getAudioDevicesSync() {
    return _queryAudioDevices();
  }

  static List<AudioDevice> _queryAudioDevices() {
    final outDevicesPtr = calloc<Pointer<native.miniaudio_device_info_t>>();
    final outCountPtr = calloc<Uint32>();

    try {
      final res = native.miniaudio_player_get_devices(
        outDevicesPtr,
        outCountPtr,
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to enumerate audio devices: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      final count = outCountPtr.value;
      final devicesPtr = outDevicesPtr.value;
      final hardwareDevices = <AudioDevice>[];
      String? defaultHardwareName;

      if (devicesPtr != nullptr) {
        for (var i = 0; i < count; i++) {
          final devC = devicesPtr[i];
          final dev = devC.toAudioDevice();
          hardwareDevices.add(dev);
          if (devC.is_default != 0 && defaultHardwareName == null) {
            defaultHardwareName = dev.name;
          }
        }
        native.miniaudio_player_free_devices(devicesPtr, count);
      }

      defaultHardwareName ??=
          hardwareDevices.isNotEmpty ? hardwareDevices.first.name : 'Default';

      final autoDevice = AudioDevice(
        id: '',
        name: 'SYSTEM DEFAULT',
        resolvedName: defaultHardwareName,
        isAuto: true,
      );

      final result = <AudioDevice>[
        autoDevice,
        ...hardwareDevices,
      ];

      _updateAudioDevices(result);
      return result;
    } finally {
      calloc.free(outDevicesPtr);
      calloc.free(outCountPtr);
    }
  }

  /// Analyzes an audio file in a single, high-performance decoding pass on a dedicated
  /// non-blocking native C background worker thread (zero Dart Isolates, zero UI frame freezing).
  ///
  /// Simultaneously extracts:
  /// - Essential track info: duration, sample rate, channels, bitrate, peak.
  /// - [ReplayGainResult] loudness & recommended volume gain (if [replayGain] is `true`).
  /// - [WaveformResult] normalized amplitude bars for seekbars/visualizers (if [waveform] is `true`).
  ///
  /// Disabling modules via `replayGain: false` or `waveform: false` skips their respective
  /// computation in C, conserving CPU cycles when only one is needed. Running both together
  /// in a single pass saves ~50% CPU and storage I/O compared to analyzing them separately.
  ///
  /// - [filePath]: Path to the local audio file (e.g. MP3, WAV, FLAC, AAC, M4A, Opus, Ogg).
  /// - [replayGain]: Whether to calculate ITU-R BS.1770-4 / EBU R128 loudness metrics (default: `true`).
  /// - [waveform]: Whether to extract normalized waveform points for seekbars (default: `true`).
  /// - [waveformPoints]: Number of bars/points to divide the audio into (default: `100`).
  /// - [targetLufs]: Loudness reference level in LUFS (defaults to `-18.0` for ReplayGain, `-14.0` for streaming).
  static Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    final completer = Completer<AudioAnalysisResult>();

    var flags = 0;
    if (replayGain) flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_REPLAY_GAIN.value;
    if (waveform) flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_WAVEFORM.value;

    late final NativeCallable<native.miniaudio_audio_analysis_completed_cbFunction>
        callback;
    callback = NativeCallable<
        native.miniaudio_audio_analysis_completed_cbFunction>.listener(
      (
        Pointer<native.miniaudio_audio_analysis_result_t> resultPtr,
        Pointer<Void> userData,
      ) {
        try {
          if (resultPtr == nullptr) {
            completer.completeError(
              const MiniaudioPlayerException('Null result received from native audio analysis'),
            );
            return;
          }

          final res = resultPtr.ref;
          if (res.status == MapResult.success) {
            final duration = Duration(milliseconds: res.duration_ms);
            final sampleRate = res.sample_rate;
            final channels = res.channels;
            final bitrate = res.bitrate;
            final peak = res.peak;

            ReplayGainResult? replayGainResult;
            if (res.has_replay_gain != 0) {
              replayGainResult = ReplayGainResult(
                gainDb: res.replay_gain.gain_db,
                peak: res.replay_gain.peak,
                lufs: res.replay_gain.lufs,
              );
            }

            WaveformResult? waveformResult;
            if (res.has_waveform != 0 && res.waveform.points != nullptr) {
              final count = res.waveform.point_count;
              final points = List<double>.generate(
                count,
                (i) => res.waveform.points[i],
                growable: false,
              );
              waveformResult = WaveformResult(points: points);
            }

            completer.complete(
              AudioAnalysisResult(
                duration: duration,
                sampleRate: sampleRate,
                channels: channels,
                bitrate: bitrate,
                peak: peak,
                replayGain: replayGainResult,
                waveform: waveformResult,
              ),
            );
          } else {
            completer.completeError(
              MiniaudioPlayerException(
                'Failed to analyze audio: ${MapResult.describe(res.status)}',
                errorCode: res.status,
              ),
            );
          }
        } finally {
          if (resultPtr != nullptr) {
            native.miniaudio_player_free_audio_analysis(resultPtr, 1);
          }
          callback.close();
        }
      },
    );

    final path =
        filePath.startsWith('file://')
            ? Uri.parse(filePath).toFilePath()
            : filePath;
    final pathPtr = path.toNativeUtf8();
    final configPtr = calloc<native.miniaudio_audio_analysis_config_t>();

    try {
      configPtr.ref.flags = flags;
      configPtr.ref.target_lufs = targetLufs;
      configPtr.ref.waveform_points = waveformPoints;

      final res = native.miniaudio_player_analyze_audio_async(
        pathPtr.cast(),
        configPtr,
        callback.nativeFunction,
        nullptr,
      );
      if (res != MapResult.success) {
        callback.close();
        throw MiniaudioPlayerException(
          'Failed to dispatch native audio analysis: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
    } catch (e) {
      callback.close();
      rethrow;
    } finally {
      calloc.free(pathPtr);
      calloc.free(configPtr);
    }

    return completer.future;
  }

  /// Synchronously analyzes an audio file in a single decoding pass.
  ///
  /// Note: This executes directly on the calling thread. For Flutter UI applications,
  /// prefer the non-blocking [analyzeAudio].
  static AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    var flags = 0;
    if (replayGain) flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_REPLAY_GAIN.value;
    if (waveform) flags |= native.miniaudio_analysis_flags_t.MAP_ANALYSIS_FLAG_WAVEFORM.value;

    final path =
        filePath.startsWith('file://')
            ? Uri.parse(filePath).toFilePath()
            : filePath;
    final pathPtr = path.toNativeUtf8();
    final configPtr = calloc<native.miniaudio_audio_analysis_config_t>();
    final outResultPtr = calloc<native.miniaudio_audio_analysis_result_t>();

    try {
      configPtr.ref.flags = flags;
      configPtr.ref.target_lufs = targetLufs;
      configPtr.ref.waveform_points = waveformPoints;

      final res = native.miniaudio_player_analyze_audio(
        pathPtr.cast(),
        configPtr,
        outResultPtr,
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to analyze audio: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      final out = outResultPtr.ref;
      final duration = Duration(milliseconds: out.duration_ms);
      final sampleRate = out.sample_rate;
      final channels = out.channels;
      final bitrate = out.bitrate;
      final peak = out.peak;

      ReplayGainResult? replayGainResult;
      if (out.has_replay_gain != 0) {
        replayGainResult = ReplayGainResult(
          gainDb: out.replay_gain.gain_db,
          peak: out.replay_gain.peak,
          lufs: out.replay_gain.lufs,
        );
      }

      WaveformResult? waveformResult;
      if (out.has_waveform != 0 && out.waveform.points != nullptr) {
        final count = out.waveform.point_count;
        final points = List<double>.generate(
          count,
          (i) => out.waveform.points[i],
          growable: false,
        );
        waveformResult = WaveformResult(points: points);
      }

      return AudioAnalysisResult(
        duration: duration,
        sampleRate: sampleRate,
        channels: channels,
        bitrate: bitrate,
        peak: peak,
        replayGain: replayGainResult,
        waveform: waveformResult,
      );
    } finally {
      if (outResultPtr != nullptr) {
        native.miniaudio_player_free_audio_analysis(outResultPtr, 0);
        calloc.free(outResultPtr);
      }
      calloc.free(pathPtr);
      calloc.free(configPtr);
    }
  }

  Pointer<native.miniaudio_player_t> _playerHandle = nullptr;
  Pointer<native.miniaudio_player_status_t>? _statusPtr;
  late final NativeCallable<native.miniaudio_player_completed_cbFunction>
      _completedCallable;

  Timer? _positionTimer;

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

  // Cached synchronous state snapshot
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _buffering = false;
  bool _completed = false;
  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;
  int _bufferSize = _globalConfig.defaultBufferSize;
  int _audioBitrate = 0;
  Equalizer _equalizer = Equalizer.flat;
  AudioDevice _audioDevice = _globalConfig.defaultAudioDevice;
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();
  Duration _silenceSavedDuration = Duration.zero;
  VisualizerData _visualizer = VisualizerData.empty();
  bool? _manualVisualizerOverride;
  bool _hasVisualizerListeners = false;

  /// Returns whether the visualizer DSP is currently active, considering
  /// explicit manual overrides and reactive stream listeners.
  bool get _isVisualizerActive =>
      _manualVisualizerOverride ?? _hasVisualizerListeners;
  Duration _currentTimerInterval = const Duration(milliseconds: 50);
  double _preamp = 0.0;
  ReplayGainConfig _replayGain = const ReplayGainConfig();
  double _balance = 0.0;
  bool _mono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  double _spatializerWidth = 1.0;
  Reverb _reverb = Reverb.off;
  bool _limiterEnabled = true;

  // Previous status cache for change detection
  Duration? _lastPosition;
  Duration? _lastDuration;
  bool? _lastIsPlaying;
  bool? _lastIsBuffering;
  int? _lastState;
  int? _lastBitrate;
  AudioDevice? _lastDevice;
  SilenceSkipConfig? _lastSilenceConfig;
  Duration? _lastSilenceSavedDuration;
  bool? _lastVisualizerEnabled;

  bool _isDisposed = false;

  static final _finalizer = NativeFinalizer(
    Native.addressOf<
      NativeFunction<Int32 Function(Pointer<native.miniaudio_player_t>)>
    >(native.miniaudio_player_destroy).cast(),
  );

  /// Action interface for controlling playback, volume, rate, pitch, buffer size, and DSP.
  late final PlayerAction action;

  /// Reactive stream interface for observing state changes.
  late final PlayerStream stream;

  /// Synchronous state snapshot interface.
  late final PlayerState state;

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
        if (_playing) _startPositionTimer();
      },
      onCancel: () {
        _hasVisualizerListeners = false;
        _updateNativeVisualizerState();
        if (_playing) _startPositionTimer();
      },
    );

    if (_globalConfig.logLevel.value > 0) {
      try {
        native.miniaudio_player_set_log_level(_globalConfig.logLevel.value);
      } catch (_) {}
    }

    _completedCallable =
        NativeCallable<native.miniaudio_player_completed_cbFunction>.listener(
            _onNativeCompleted);

    final outResult = calloc<Int32>();
    try {
      Pointer<Utf8>? devIdPtr;
      if (_audioDevice.id.isNotEmpty && _audioDevice.id != 'auto') {
        devIdPtr = _audioDevice.id.toNativeUtf8();
      }

      final configPtr = native.miniaudio_player_config_t.$allocate(
        calloc,
        sample_rate: 0,
        channels: 0,
        period_size_in_frames: _bufferSize > 0 ? _bufferSize : 0,
        playback_device_id: devIdPtr != null ? devIdPtr.cast() : nullptr,
        on_completed: _completedCallable.nativeFunction,
        user_data: nullptr,
      );

      try {
        _playerHandle = native.miniaudio_player_create(configPtr, outResult);
      } finally {
        if (devIdPtr != null) calloc.free(devIdPtr);
        calloc.free(configPtr);
      }

      final result = outResult.value;
      if (_playerHandle == nullptr || result != MapResult.success) {
        _completedCallable.close();
        throw MiniaudioPlayerException(
          'Failed to create native audio engine: code $result',
          errorCode: result,
        );
      }

      _finalizer.attach(this, _playerHandle.cast(), detach: this);

      _statusPtr = calloc<native.miniaudio_player_status_t>();

      final devPtr = calloc<native.miniaudio_device_info_t>();
      try {
        if (native.miniaudio_player_get_current_device(_playerHandle, devPtr) ==
            MapResult.success) {
          _audioDevice = devPtr.ref.toAudioDevice();
        }
      } finally {
        calloc.free(devPtr);
      }
    } finally {
      calloc.free(outResult);
    }

    action = PlayerAction(
      this,
      onOptimisticSeek: (pos) {
        _position = pos;
        _lastPosition = pos;
        if (!_positionController.isClosed) {
          _positionController.add(_position);
        }
      },
    );

    stream = PlayerStream(
      positionController: _positionController,
      durationController: _durationController,
      playingController: _playingController,
      bufferingController: _bufferingController,
      completedController: _completedController,
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
    );

    state = PlayerState(
      getPosition: () => _position,
      getDuration: () => _duration,
      getPlaying: () => _playing,
      getBuffering: () => _buffering,
      getCompleted: () => _completed,
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
    );
  }

  /// Returns the currently active audio output device.
  AudioDevice getAudioDevice() {
    if (_isDisposed || _playerHandle == nullptr) {
      return _audioDevice;
    }
    final devPtr = calloc<native.miniaudio_device_info_t>();
    try {
      if (native.miniaudio_player_get_current_device(_playerHandle, devPtr) ==
          MapResult.success) {
        var dev = devPtr.ref.toAudioDevice();
        if (dev.isAuto &&
            (dev.resolvedName == null || dev.resolvedName!.isEmpty)) {
          final devices = _cachedAudioDevices;
          for (final d in devices) {
            if (!d.isAuto) {
              dev = AudioDevice(
                id: '',
                name: 'SYSTEM DEFAULT',
                resolvedName: d.name,
                isAuto: true,
              );
              break;
            }
          }
        }
        _audioDevice = dev;
      }
    } finally {
      calloc.free(devPtr);
    }
    return _audioDevice;
  }

  /// Internal handle to the native miniaudio player.
  Pointer<native.miniaudio_player_t> get handle => _playerHandle;

  /// Ensures that the player has not been disposed.
  void ensureNotDisposed() {
    if (_isDisposed || _playerHandle == nullptr) {
      throw MiniaudioPlayerException(
        'Player is already disposed',
        errorCode: MapResult.errorInvalidState,
      );
    }
  }

  void _updateNativeVisualizerState() {
    if (_isDisposed || _playerHandle == nullptr) return;
    final shouldEnable = _isVisualizerActive;
    native.miniaudio_player_set_visualizer_enabled(
      _playerHandle,
      shouldEnable ? 1 : 0,
    );
    if (!shouldEnable) {
      _visualizer = VisualizerData.empty();
      if (!_visualizerController.isClosed && _hasVisualizerListeners) {
        _visualizerController.add(VisualizerData.empty());
      }
    }
    if (_lastVisualizerEnabled != shouldEnable) {
      _lastVisualizerEnabled = shouldEnable;
      if (!_visualizerEnabledController.isClosed) {
        _visualizerEnabledController.add(shouldEnable);
      }
    }
  }

  /// Sets or clears the explicit manual visualizer override.
  ///
  /// When `false`, visualizer DSP is forced disabled even if stream listeners exist.
  /// When `true`, visualizer DSP is forced enabled even without stream listeners.
  /// When `null`, visualizer DSP is governed reactively by stream listeners on demand.
  void setManualVisualizerOverride(bool? override) {
    _manualVisualizerOverride = override;
    _updateNativeVisualizerState();
    if (_playing) {
      _startPositionTimer();
    }
  }

  /// Sets whether the visualizer DSP is manually forced enabled or disabled.
  /// (Maintained for backward compatibility, delegates to [setManualVisualizerOverride]).
  void setManualVisualizerEnabled(bool enabled) {
    setManualVisualizerOverride(enabled);
  }

  /// Notifies the player that playback was stopped manually.
  ///
  /// Resets internal completion and playback flags, rewinds position,
  /// and cancels active polling timers.
  void notifyStopped() {
    if (_isDisposed) return;
    _stopPositionTimer();
    final wasPlaying = _playing;
    final wasCompleted = _completed;
    _playing = false;
    _completed = false;
    _lastIsPlaying = false;
    _position = Duration.zero;
    _lastPosition = Duration.zero;
    _visualizer = VisualizerData.empty();

    if (!_visualizerController.isClosed && _isVisualizerActive) {
      _visualizerController.add(VisualizerData.empty());
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

  void _onNativeCompleted(Pointer<Void> _) {
    if (_isDisposed) return;
    _stopPositionTimer();
    final wasPlaying = _playing;
    final wasCompleted = _completed;
    _playing = false;
    _completed = true;
    _lastIsPlaying = false;
    _position = _duration;
    _lastPosition = _duration;
    _visualizer = VisualizerData.empty();

    if (!_visualizerController.isClosed && _isVisualizerActive) {
      _visualizerController.add(VisualizerData.empty());
    }

    if (!_playingController.isClosed && wasPlaying) {
      _playingController.add(false);
    }
    if (!_completedController.isClosed && !wasCompleted && wasPlaying) {
      _completedController.add(true);
    }
    if (!_positionController.isClosed) {
      _positionController.add(_duration);
    }
  }

  void _startPositionTimer() {
    final isVisActive = _isVisualizerActive;
    final interval = isVisActive
        ? const Duration(milliseconds: 33)
        : const Duration(milliseconds: 50);

    if (_positionTimer != null && _positionTimer!.isActive) {
      if (_currentTimerInterval == interval) return;
      _positionTimer!.cancel();
    }
    _currentTimerInterval = interval;
    _positionTimer = Timer.periodic(interval, (_) {
      if (_isDisposed || _playerHandle == nullptr) {
        _stopPositionTimer();
        return;
      }
      pollAndEmit(force: false);
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
    _visualizer = VisualizerData.empty();
    if (!_visualizerController.isClosed && _isVisualizerActive) {
      _visualizerController.add(VisualizerData.empty());
    }
  }

  /// Queries the native miniaudio player snapshot and emits changes to broadcast streams.
  bool pollAndEmit({bool force = false}) {
    if (_isDisposed || _statusPtr == null || _playerHandle == nullptr) {
      return false;
    }

    final res = native.miniaudio_player_get_status(_playerHandle, _statusPtr!);
    if (res != MapResult.success) {
      return false;
    }

    final status = _statusPtr!.ref;
    final position = Duration(milliseconds: status.position_ms);
    final duration = Duration(milliseconds: status.duration_ms);
    final isPlaying = status.is_playing != 0;
    final isBuffering = status.is_buffering != 0;
    final isCompleted = status.is_completed != 0;
    final state = status.state;
    final bitrate = status.bitrate;
    final device = status.device.toAudioDevice();
    final silenceConfig = SilenceSkipConfig.fromNative(status.silence);
    final silenceSavedDuration = Duration(milliseconds: status.silence_saved_ms);

    final bool deviceChanged = _lastDevice == null ||
        _lastDevice!.id != device.id ||
        _lastDevice!.name != device.name ||
        _lastDevice!.isAuto != device.isAuto ||
        _lastDevice!.resolvedName != device.resolvedName;

    if (deviceChanged) {
      _lastDevice = device;
      _audioDevice = device;
      if (!_audioDeviceController.isClosed) {
        _audioDeviceController.add(device);
      }
    }

    final bool playingChanged =
        _lastIsPlaying == null || isPlaying != _lastIsPlaying;
    final bool bufferingChanged =
        _lastIsBuffering == null || isBuffering != _lastIsBuffering;
    final bool stateIntChanged = _lastState == null || state != _lastState;
    final bool wasActivelyPlaying = _playing || (_lastIsPlaying == true);

    if (playingChanged || bufferingChanged || stateIntChanged || force) {
      _lastIsPlaying = isPlaying;
      _lastIsBuffering = isBuffering;
      _lastState = state;
      _playing = isPlaying;
      _buffering = isBuffering;

      if ((playingChanged || force) && !_playingController.isClosed) {
        _playingController.add(isPlaying);
      }
      if ((bufferingChanged || force) && !_bufferingController.isClosed) {
        _bufferingController.add(isBuffering);
      }

      if (isPlaying) {
        _startPositionTimer();
      } else {
        _stopPositionTimer();
      }
    }

    // Terminal completed stream events are edge-triggered and decoupled from [force].
    if (!_completed && isCompleted && wasActivelyPlaying) {
      _completed = true;
      if (!_completedController.isClosed) {
        _completedController.add(true);
      }
    } else if (_completed && !isCompleted) {
      _completed = false;
      if (!_completedController.isClosed) {
        _completedController.add(false);
      }
    } else {
      _completed = isCompleted;
    }

    if (duration != _lastDuration || force) {
      _lastDuration = duration;
      _duration = duration;
      if (!_durationController.isClosed) {
        _durationController.add(duration);
      }
    }

    if (bitrate != _lastBitrate || force) {
      _lastBitrate = bitrate;
      _audioBitrate = bitrate;
      if (!_audioBitrateController.isClosed) {
        _audioBitrateController.add(bitrate);
      }
    }

    final bool positionChanged =
        _lastPosition == null || position != _lastPosition;

    if (positionChanged || force) {
      _lastPosition = position;
      _position = position;
      if (!_positionController.isClosed) {
        _positionController.add(position);
      }
    }

    final bool silenceConfigChanged =
        _lastSilenceConfig == null || _lastSilenceConfig != silenceConfig;
    if (silenceConfigChanged || force) {
      final wasEnabled = _lastSilenceConfig?.mode != SilenceSkipMode.disabled;
      final isEnabled = silenceConfig.mode != SilenceSkipMode.disabled;
      _lastSilenceConfig = silenceConfig;
      _silenceConfig = silenceConfig;

      if ((wasEnabled != isEnabled || force) &&
          !_skipSilenceController.isClosed) {
        _skipSilenceController.add(isEnabled);
      }
      if (!_silenceConfigController.isClosed) {
        _silenceConfigController.add(silenceConfig);
      }
    }

    if (_lastSilenceSavedDuration != silenceSavedDuration || force) {
      _lastSilenceSavedDuration = silenceSavedDuration;
      _silenceSavedDuration = silenceSavedDuration;
      if (!_silenceSavedDurationController.isClosed) {
        _silenceSavedDurationController.add(silenceSavedDuration);
      }
    }

    if (_isVisualizerActive) {
      final visData = status.visualizer;
      final visBands = List<double>.generate(
        10,
        (i) => visData.bands[i],
        growable: false,
      );
      final currentVis = isPlaying
          ? VisualizerData(
              bands: visBands,
              rms: visData.rms,
              peak: visData.peak,
              left: visData.left,
              right: visData.right,
            )
          : VisualizerData.empty();
      _visualizer = currentVis;
      if (!_visualizerController.isClosed && _hasVisualizerListeners) {
        _visualizerController.add(currentVis);
      }
    } else {
      _visualizer = VisualizerData.empty();
    }

    final preamp = status.preamp_db;
    if (_preamp != preamp || force) {
      _preamp = preamp;
      if (!_preampController.isClosed) {
        _preampController.add(preamp);
      }
    }

    final nativeRg = status.replay_gain;
    final rg = ReplayGainConfig(
      gainDb: nativeRg.gain_db,
      peak: nativeRg.peak,
      preampDb: nativeRg.preamp_db,
      preventClipping: nativeRg.prevent_clipping != 0,
      enabled: nativeRg.enabled != 0,
    );
    if (_replayGain != rg || force) {
      _replayGain = rg;
      if (!_replayGainController.isClosed) {
        _replayGainController.add(rg);
      }
    }

    final balance = status.balance;
    if (_balance != balance || force) {
      _balance = balance;
      if (!_balanceController.isClosed) {
        _balanceController.add(balance);
      }
    }

    final mono = status.mono_enabled != 0;
    if (_mono != mono || force) {
      _mono = mono;
      if (!_monoController.isClosed) {
        _monoController.add(mono);
      }
    }

    final crossfeedMode = (status.crossfeed_mode >= 0 &&
            status.crossfeed_mode < CrossfeedMode.values.length)
        ? CrossfeedMode.values[status.crossfeed_mode]
        : CrossfeedMode.off;
    if (_crossfeed != crossfeedMode || force) {
      _crossfeed = crossfeedMode;
      if (!_crossfeedController.isClosed) {
        _crossfeedController.add(crossfeedMode);
      }
    }

    final spatializerEnabled = status.spatializer_enabled != 0;
    if (_spatializerEnabled != spatializerEnabled || force) {
      _spatializerEnabled = spatializerEnabled;
      if (!_spatializerEnabledController.isClosed) {
        _spatializerEnabledController.add(spatializerEnabled);
      }
    }

    final spatializerWidth = status.spatializer_width;
    if (_spatializerWidth != spatializerWidth || force) {
      _spatializerWidth = spatializerWidth;
      if (!_spatializerWidthController.isClosed) {
        _spatializerWidthController.add(spatializerWidth);
      }
    }

    final nativeReverb = status.reverb;
    final reverb = Reverb(
      enabled: nativeReverb.enabled != 0,
      roomSize: nativeReverb.room_size,
      damping: nativeReverb.damping,
      width: nativeReverb.width,
      wet: nativeReverb.wet,
      dry: nativeReverb.dry,
    );
    if (_reverb != reverb || force) {
      _reverb = reverb;
      if (!_reverbController.isClosed) {
        _reverbController.add(reverb);
      }
    }

    final limiterEnabled = status.limiter_enabled != 0;
    if (_limiterEnabled != limiterEnabled || force) {
      _limiterEnabled = limiterEnabled;
      if (!_limiterEnabledController.isClosed) {
        _limiterEnabledController.add(limiterEnabled);
      }
    }

    return true;
  }

  void notifyVolumeChanged(double volume) {
    if (_isDisposed) return;
    _volume = volume;
    if (!_volumeController.isClosed) {
      _volumeController.add(volume);
    }
  }

  void notifyRateChanged(double rate) {
    if (_isDisposed) return;
    _rate = rate;
    if (!_rateController.isClosed) {
      _rateController.add(rate);
    }
  }

  void notifyPitchChanged(double pitch) {
    if (_isDisposed) return;
    _pitch = pitch;
    if (!_pitchController.isClosed) {
      _pitchController.add(pitch);
    }
  }

  void notifyBufferSizeChanged(int bufferSize) {
    if (_isDisposed) return;
    _bufferSize = bufferSize;
    if (!_bufferSizeController.isClosed) {
      _bufferSizeController.add(bufferSize);
    }
  }

  void notifyEqualizerChanged(Equalizer equalizer) {
    if (_isDisposed) return;
    _equalizer = equalizer;
    if (!_equalizerController.isClosed) {
      _equalizerController.add(equalizer);
    }
  }

  void notifyDeviceChanged(AudioDevice device) {
    if (_isDisposed) return;
    _audioDevice = device;
    _lastDevice = device;
    if (!_audioDeviceController.isClosed) {
      _audioDeviceController.add(device);
    }
  }

  void notifySilenceConfigChanged(SilenceSkipConfig config) {
    if (_isDisposed) return;
    final wasEnabled = _silenceConfig.mode != SilenceSkipMode.disabled;
    final isEnabled = config.mode != SilenceSkipMode.disabled;
    _silenceConfig = config;
    _lastSilenceConfig = config;

    if (wasEnabled != isEnabled && !_skipSilenceController.isClosed) {
      _skipSilenceController.add(isEnabled);
    }
    if (!_silenceConfigController.isClosed) {
      _silenceConfigController.add(config);
    }
  }

  /// Sets the active audio output device.
  Future<bool> setDevice(AudioDevice device) => action.setDevice(device);

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  /// Current internal buffer size in frames (0 = native default).
  int get bufferSize => _bufferSize;

  /// Current audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  int get audioBitrate => _audioBitrate;

  /// Alias for [audioBitrate].
  int get bitrate => _audioBitrate;

  /// Destroys the player instance and frees native C memory.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    _finalizer.detach(this);
    _stopPositionTimer();
    _completedCallable.close();

    if (_playerHandle != nullptr) {
      native.miniaudio_player_destroy(_playerHandle);
      _playerHandle = nullptr;
    }

    if (_statusPtr != null) {
      calloc.free(_statusPtr!);
      _statusPtr = null;
    }

    await _positionController.close();
    await _durationController.close();
    await _playingController.close();
    await _bufferingController.close();
    await _completedController.close();
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
  }
}
