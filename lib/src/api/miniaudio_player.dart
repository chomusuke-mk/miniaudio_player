import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

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
import 'buffered_range.dart';
import 'track_metadata.dart';
import '../network/network_audio_streamer.dart';
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

  /// Buffer duration ahead of playback cursor (default: 15s).
  Duration bufferAheadDuration;

  /// Buffer duration retained behind playback cursor in circular RAM cache (default: 15s).
  Duration bufferBehindDuration;

  /// Default buffer duration for local files (default: 30s).
  Duration bufferLocalDuration;

  /// Default buffer duration for progressive network streams (default: 30s).
  Duration bufferNetworkDuration;

  /// Default buffer duration for continuous live streams (default: 15s).
  Duration bufferLiveStreamDuration;

  /// Optional buffer cap in MB for local files.
  int? bufferSizeLocalMB;

  /// Optional buffer cap in MB for progressive network streams.
  int? bufferSizeNetworkMB;

  /// Optional buffer cap in MB for live streams.
  int? bufferSizeLiveStreamMB;

  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
    this.defaultAudioDevice = AudioDevice.auto,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    this.bufferAheadDuration = const Duration(seconds: 15),
    this.bufferBehindDuration = const Duration(seconds: 15),
    this.bufferLocalDuration = const Duration(seconds: 30),
    this.bufferNetworkDuration = const Duration(seconds: 30),
    this.bufferLiveStreamDuration = const Duration(seconds: 15),
    this.bufferSizeLocalMB,
    this.bufferSizeNetworkMB = 8,
    this.bufferSizeLiveStreamMB,
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

  /// Currently active global player configuration.
  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;

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
    Duration? bufferAheadDuration,
    Duration? bufferBehindDuration,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    int? bufferLocalInSeconds,
    int? bufferNetworkInSeconds,
    int? bufferLiveStreamInSeconds,
    int? bufferStreamsInSeconds,
    int? bufferSizeLocalMB,
    int? bufferSizeNetworkMB,
    int? bufferSizeLiveStreamMB,
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
    if (bufferAheadDuration != null) {
      _globalConfig.bufferAheadDuration = bufferAheadDuration;
    }
    if (bufferBehindDuration != null) {
      _globalConfig.bufferBehindDuration = bufferBehindDuration;
    }
    if (bufferLocalDuration != null) {
      _globalConfig.bufferLocalDuration = bufferLocalDuration;
    } else if (bufferLocalInSeconds != null) {
      _globalConfig.bufferLocalDuration = Duration(seconds: bufferLocalInSeconds);
    }
    if (bufferNetworkDuration != null) {
      _globalConfig.bufferNetworkDuration = bufferNetworkDuration;
    } else if (bufferNetworkInSeconds != null) {
      _globalConfig.bufferNetworkDuration = Duration(seconds: bufferNetworkInSeconds);
    }
    if (bufferLiveStreamDuration != null) {
      _globalConfig.bufferLiveStreamDuration = bufferLiveStreamDuration;
    } else if (bufferLiveStreamInSeconds != null) {
      _globalConfig.bufferLiveStreamDuration = Duration(seconds: bufferLiveStreamInSeconds);
    } else if (bufferStreamsInSeconds != null) {
      _globalConfig.bufferLiveStreamDuration = Duration(seconds: bufferStreamsInSeconds);
    }
    if (bufferSizeLocalMB != null) {
      _globalConfig.bufferSizeLocalMB = bufferSizeLocalMB;
    }
    if (bufferSizeNetworkMB != null) {
      _globalConfig.bufferSizeNetworkMB = bufferSizeNetworkMB;
    }
    if (bufferSizeLiveStreamMB != null) {
      _globalConfig.bufferSizeLiveStreamMB = bufferSizeLiveStreamMB;
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
  late final NativeCallable<native.miniaudio_player_completed_cbFunction>
      _completedCallable;
  late final NativeCallable<native.miniaudio_player_event_cbFunction>
      _eventCallable;

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
  int _cachedMetaVersion = 0;
  Uint8List? _cachedMetaBytes;
  Duration _bufferedPosition = Duration.zero;
  double _bufferedPercentage = 0.0;
  BufferedRange _bufferedRange = const BufferedRange();
  AudioTrackMetadata? _trackMetadata;
  BufferedRange? _lastBufferedRange;
  AudioTrackMetadata? _lastTrackMetadata;
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
  double _preamp = 0.0;
  ReplayGainConfig _replayGain = const ReplayGainConfig();
  double _balance = 0.0;
  bool _mono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  double _spatializerWidth = 1.0;
  Reverb _reverb = Reverb.off;
  bool _limiterEnabled = true;

  bool? _lastVisualizerEnabled = false;

  bool _isDisposed = false;

  /// Broadcast stream of opening state (`true` while preparing audio source, `false` otherwise).
  Stream<bool> get opening => stream.opening;

  /// Broadcast stream of current playback lifecycle state.
  Stream<PlaybackState> get playbackState => stream.playbackState;

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

  /// Active network audio streamer instance, if an HTTP/HTTPS source is loaded.
  NetworkAudioStreamer? get streamer => action.activeStreamer;

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

      _eventCallable =
          NativeCallable<native.miniaudio_player_event_cbFunction>.listener(
              _onNativeEvent);
      native.miniaudio_player_set_event_callback(
        _playerHandle,
        _eventCallable.nativeFunction,
        nullptr,
      );

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

  /// Native audio sampling rate in Hz of the currently active source (or engine default).
  int get sampleRate {
    if (_isDisposed || _playerHandle == nullptr) return 0;
    return native.miniaudio_player_get_sample_rate(_playerHandle);
  }

  /// Channel count of the currently active source (e.g. 1 for mono, 2 for stereo).
  int get channels {
    if (_isDisposed || _playerHandle == nullptr) return 0;
    return native.miniaudio_player_get_channels(_playerHandle);
  }

  /// Buffer duration to preload ahead of current playback position.
  Duration get bufferAheadDuration => _globalConfig.bufferAheadDuration;

  /// Buffer duration to retain behind current playback position.
  Duration get bufferBehindDuration => _globalConfig.bufferBehindDuration;

  /// Default buffer window for local files.
  Duration get bufferLocalDuration => _globalConfig.bufferLocalDuration;

  /// Default buffer window for progressive network audio.
  Duration get bufferNetworkDuration => _globalConfig.bufferNetworkDuration;

  /// Default buffer window for continuous live streams.
  Duration get bufferLiveStreamDuration => _globalConfig.bufferLiveStreamDuration;

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
  }

  /// Sets or clears the explicit manual visualizer override.
  ///
  /// When `false`, visualizer DSP is forced disabled even if stream listeners exist.
  /// When `true`, visualizer DSP is forced enabled even without stream listeners.
  /// When `null`, visualizer DSP is governed reactively by stream listeners on demand.
  void setManualVisualizerOverride(bool? override) {
    _manualVisualizerOverride = override;
    _updateNativeVisualizerState();
  }

  /// Sets whether the visualizer DSP is manually forced enabled or disabled.
  /// (Maintained for backward compatibility, delegates to [setManualVisualizerOverride]).
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
    if (_playerHandle != nullptr) {
      final durMs = native.miniaudio_player_get_duration_ms(_playerHandle);
      if (durMs > 0) {
        final dur = Duration(milliseconds: durMs);
        if (_duration != dur) {
          _duration = dur;
          if (!_durationController.isClosed) {
            _durationController.add(dur);
          }
        }
      }
    }
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

  /// Explicitly resets cached metadata to null and emits null on the metadata stream.
  void resetMetadata() {
    _cachedMetaBytes = null;
    _cachedMetaVersion = 0;
    _trackMetadata = null;
    _lastTrackMetadata = null;
    if (!_metaBytesController.isClosed) {
      _metaBytesController.add(null);
    }
    if (!_trackMetadataController.isClosed) {
      _trackMetadataController.add(null);
    }
  }

  /// Synthesizes or retrieves cached metadata container bytes for safe parsing by pub.dev libraries.
  Uint8List? _getMetaBytes() {
    if (_isDisposed || _playerHandle == nullptr) {
      return _cachedMetaBytes;
    }
    final currentVer =
        native.miniaudio_player_get_meta_bytes_version(_playerHandle);
    if (currentVer != _cachedMetaVersion) {
      _cachedMetaVersion = currentVer;
      final size = native.miniaudio_player_get_meta_bytes_size(_playerHandle);
      if (size > 0) {
        final ptr = calloc<Uint8>(size);
        try {
          final copied = native.miniaudio_player_copy_meta_bytes(
            _playerHandle,
            ptr,
            size,
          );
          if (copied > 0) {
            _cachedMetaBytes = Uint8List.fromList(ptr.asTypedList(copied));
          } else {
            _cachedMetaBytes = null;
          }
        } finally {
          calloc.free(ptr);
        }
      } else {
        _cachedMetaBytes = null;
      }
      if (!_metaBytesController.isClosed) {
        _metaBytesController.add(_cachedMetaBytes);
      }
    }
    return _cachedMetaBytes;
  }

  /// Checks if native metadata has updated and updates cached copy if so.
  void checkMetaBytesUpdated() {
    if (_isDisposed || _playerHandle == nullptr) return;
    final currentVer =
        native.miniaudio_player_get_meta_bytes_version(_playerHandle);
    if (currentVer != _cachedMetaVersion) {
      _getMetaBytes();
    }
  }

  /// Ingests dynamic ICY livestream metadata received over network.
  void setIcyMeta(Uint8List data) => action.setIcyMeta(data);

  /// Probes tail metadata (ID3v1, APEv2, MP4 moov, etc.) directly into buffer Tail.
  void probeTail(Uint8List data, int tailOffset) =>
      action.probeTail(data, tailOffset);

  /// Returns the current number of bytes retained in the pinned Head cache.
  int get pinnedHeadSize {
    if (_isDisposed || _playerHandle == nullptr) return 0;
    return native.miniaudio_player_stream_get_pinned_head_size(_playerHandle);
  }

  void notifyOpenComplete() => notifyOpenCompleted();

  /// Notifies that opening failed due to an error.
  void notifyOpenFailed([Object? error]) {
    if (_isDisposed) return;
    try {
      if (_playerHandle != nullptr) {
        native.miniaudio_player_stop(_playerHandle);
      }
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
  ///
  /// Resets internal completion and playback flags, rewinds position,
  /// and cancels active polling timers.
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

  void _onNativeCompleted(Pointer<Void> _) {
    if (_isDisposed || _playerHandle == nullptr) return;

    if (native.miniaudio_player_is_playing(_playerHandle) != 0) {
      return;
    }

    final wasPlaying = _playing;
    final wasCompleted = _completed;
    _playing = false;
    _completed = true;
    _playbackState = PlaybackState.completed;
    _position = _duration;
    _visualizer = VisualizerData.empty();

    if (!_visualizerController.isClosed && _isVisualizerActive) {
      _visualizerController.add(VisualizerData.empty());
    }

    if (!_playbackStateController.isClosed) {
      _playbackStateController.add(PlaybackState.completed);
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

  void _onNativeEvent(
      Pointer<Void> userData, Pointer<native.map_event> eventPtr) {
    if (_isDisposed) return;

    final event = eventPtr.ref;
    final type = event.type;

    if (type == native.map_event_type_t.MAP_EVENT_STATE.value) {
      final stateInt = event.data.state;
      final PlaybackState newState;
      switch (stateInt) {
        case MapPlaybackState.stopped:
          newState = PlaybackState.stopped;
          break;
        case MapPlaybackState.playing:
          newState = PlaybackState.playing;
          break;
        case MapPlaybackState.paused:
          newState = PlaybackState.paused;
          break;
        case MapPlaybackState.completed:
          newState = PlaybackState.completed;
          break;
        case MapPlaybackState.buffering:
          newState = PlaybackState.buffering;
          break;
        case MapPlaybackState.error:
          newState = PlaybackState.error;
          break;
        case MapPlaybackState.opening:
          newState = PlaybackState.opening;
          break;
        default:
          newState = PlaybackState.stopped;
          break;
      }
      if (_playbackState == PlaybackState.error && newState == PlaybackState.stopped) {
        return;
      }
      final bool isOpening = newState == PlaybackState.opening;
      if (isOpening != _opening) {
        _opening = isOpening;
        if (!_openingController.isClosed) {
          _openingController.add(isOpening);
        }
      }
      if (newState == PlaybackState.stopped || newState == PlaybackState.playing) {
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
    } else if (type == native.map_event_type_t.MAP_EVENT_POSITION.value) {
      final pos = Duration(milliseconds: event.data.position_ms);
      if (_position != pos) {
        _position = pos;
        if (!_positionController.isClosed) {
          _positionController.add(pos);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_DURATION.value) {
      final dur = Duration(milliseconds: event.data.duration_ms);
      if (_duration != dur) {
        _duration = dur;
        if (!_durationController.isClosed) {
          _durationController.add(dur);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_PLAYING.value) {
      final isPlaying = event.data.is_playing != 0;
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
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_BUFFERING.value) {
      final isBuffering = event.data.is_buffering != 0;
      if (_buffering != isBuffering) {
        _buffering = isBuffering;
        if (!_bufferingController.isClosed) {
          _bufferingController.add(isBuffering);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_IS_COMPLETED.value) {
      final isCompleted = event.data.is_completed != 0;
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
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_VOLUME.value) {
      notifyVolumeChanged(double.parse(event.data.volume.toStringAsPrecision(7)));
    } else if (type == native.map_event_type_t.MAP_EVENT_RATE.value) {
      notifyRateChanged(double.parse(event.data.rate.toStringAsPrecision(7)));
    } else if (type == native.map_event_type_t.MAP_EVENT_PITCH.value) {
      notifyPitchChanged(double.parse(event.data.pitch.toStringAsPrecision(7)));
    } else if (type == native.map_event_type_t.MAP_EVENT_BITRATE.value) {
      final br = event.data.bitrate;
      if (_audioBitrate != br) {
        _audioBitrate = br;
        if (!_audioBitrateController.isClosed) {
          _audioBitrateController.add(br);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_BUFFER_SIZE.value) {
      notifyBufferSizeChanged(event.data.buffer_size);
    } else if (type == native.map_event_type_t.MAP_EVENT_DEVICE.value) {
      notifyDeviceChanged(event.data.device.toAudioDevice());
    } else if (type == native.map_event_type_t.MAP_EVENT_VISUALIZER.value) {
      if (_isVisualizerActive) {
        final visData = event.data.visualizer;
        final visBands = List<double>.generate(
          10,
          (i) => visData.bands[i],
          growable: false,
        );
        final currentVis = _playing
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
    } else if (type == native.map_event_type_t.MAP_EVENT_VISUALIZER_ENABLED.value) {
      final ve = event.data.visualizer_enabled != 0;
      if (_lastVisualizerEnabled != ve) {
        _lastVisualizerEnabled = ve;
        if (!_visualizerEnabledController.isClosed) {
          _visualizerEnabledController.add(ve);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_BUFFERED_RANGE.value) {
      final brRef = event.data.buffered_range;
      final br = BufferedRange(
        start: Duration(milliseconds: brRef.start_ms),
        end: Duration(milliseconds: brRef.end_ms),
        duration: Duration(milliseconds: brRef.duration_ms),
        fillPercentage: brRef.fill_percentage,
        streamPercentage: brRef.stream_percentage,
        isBuffering: brRef.is_buffering != 0,
        isEof: brRef.is_eof != 0,
      );
      _bufferedPosition = br.end;
      _bufferedPercentage = br.streamPercentage;
      _bufferedRange = br;
      if (_lastBufferedRange == null || _lastBufferedRange != br) {
        _lastBufferedRange = br;
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
    } else if (type == native.map_event_type_t.MAP_EVENT_SILENCE_CONFIG.value) {
      notifySilenceConfigChanged(
        SilenceSkipConfig.fromNative(event.data.silence_config),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_SILENCE_SAVED.value) {
      final ss = Duration(milliseconds: event.data.silence_saved_ms);
      if (_silenceSavedDuration != ss) {
        _silenceSavedDuration = ss;
        if (!_silenceSavedDurationController.isClosed) {
          _silenceSavedDurationController.add(ss);
        }
      }
    } else if (type == native.map_event_type_t.MAP_EVENT_EQUALIZER.value) {
      final eqData = event.data.equalizer;
      notifyEqualizerChanged(
        Equalizer(
          hz31: eqData.hz31,
          hz63: eqData.hz63,
          hz125: eqData.hz125,
          hz250: eqData.hz250,
          hz500: eqData.hz500,
          hz1k: eqData.hz1k,
          hz2k: eqData.hz2k,
          hz4k: eqData.hz4k,
          hz8k: eqData.hz8k,
          hz16k: eqData.hz16k,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_PREAMP.value) {
      notifyPreampChanged(double.parse(event.data.preamp_db.toStringAsPrecision(7)));
    } else if (type == native.map_event_type_t.MAP_EVENT_REPLAY_GAIN.value) {
      final rgData = event.data.replay_gain;
      notifyReplayGainChanged(
        ReplayGainConfig(
          gainDb: double.parse(rgData.gain_db.toStringAsPrecision(7)),
          peak: double.parse(rgData.peak.toStringAsPrecision(7)),
          preampDb: double.parse(rgData.preamp_db.toStringAsPrecision(7)),
          preventClipping: rgData.prevent_clipping != 0,
          enabled: rgData.enabled != 0,
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_BALANCE.value) {
      notifyBalanceChanged(double.parse(event.data.balance.toStringAsPrecision(7)));
    } else if (type == native.map_event_type_t.MAP_EVENT_MONO.value) {
      notifyMonoChanged(event.data.mono_enabled != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_CROSSFEED.value) {
      final cfInt = event.data.crossfeed_mode;
      final cf = switch (cfInt) {
        1 => CrossfeedMode.moffatBauer,
        2 => CrossfeedMode.chuMoy,
        _ => CrossfeedMode.off,
      };
      notifyCrossfeedChanged(cf);
    } else if (type == native.map_event_type_t.MAP_EVENT_SPATIALIZER.value) {
      final sp = event.data.spatializer;
      notifySpatializerChanged(
        enabled: sp.enabled != 0,
        width: double.parse(sp.width.toStringAsPrecision(7)),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_REVERB.value) {
      final rv = event.data.reverb;
      notifyReverbChanged(
        Reverb(
          enabled: rv.enabled != 0,
          roomSize: double.parse(rv.room_size.toStringAsPrecision(7)),
          damping: double.parse(rv.damping.toStringAsPrecision(7)),
          width: double.parse(rv.width.toStringAsPrecision(7)),
          wet: double.parse(rv.wet.toStringAsPrecision(7)),
          dry: double.parse(rv.dry.toStringAsPrecision(7)),
        ),
      );
    } else if (type == native.map_event_type_t.MAP_EVENT_LIMITER.value) {
      notifyLimiterChanged(event.data.limiter_enabled != 0);
    } else if (type == native.map_event_type_t.MAP_EVENT_ERROR.value) {
      if (_playbackState != PlaybackState.error) {
        _playbackState = PlaybackState.error;
        if (!_playbackStateController.isClosed) {
          _playbackStateController.add(PlaybackState.error);
        }
      }
    }
    checkMetaBytesUpdated();
  }

  void notifyVolumeChanged(double volume) {
    if (_isDisposed) return;
    if (_volume == volume) return;
    _volume = volume;
    if (!_volumeController.isClosed) {
      _volumeController.add(volume);
    }
  }

  void notifyRateChanged(double rate) {
    if (_isDisposed) return;
    if (_rate == rate) return;
    _rate = rate;
    if (!_rateController.isClosed) {
      _rateController.add(rate);
    }
  }

  void notifyPitchChanged(double pitch) {
    if (_isDisposed) return;
    if (_pitch == pitch) return;
    _pitch = pitch;
    if (!_pitchController.isClosed) {
      _pitchController.add(pitch);
    }
  }

  void notifyBufferSizeChanged(int bufferSize) {
    if (_isDisposed) return;
    if (_bufferSize == bufferSize) return;
    _bufferSize = bufferSize;
    if (!_bufferSizeController.isClosed) {
      _bufferSizeController.add(bufferSize);
    }
  }

  void notifyEqualizerChanged(Equalizer equalizer) {
    if (_isDisposed) return;
    if (_equalizer == equalizer) return;
    _equalizer = equalizer;
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
    if (_silenceConfig == config) return;
    final wasEnabled = _silenceConfig.mode != SilenceSkipMode.disabled;
    final isEnabled = config.mode != SilenceSkipMode.disabled;
    _silenceConfig = config;

    if (wasEnabled != isEnabled && !_skipSilenceController.isClosed) {
      _skipSilenceController.add(isEnabled);
    }
    if (!_silenceConfigController.isClosed) {
      _silenceConfigController.add(config);
    }
  }

  void notifyReplayGainChanged(ReplayGainConfig config) {
    if (_isDisposed) return;
    if (_replayGain == config) return;
    _replayGain = config;
    if (!_replayGainController.isClosed) {
      _replayGainController.add(config);
    }
  }

  void notifyPreampChanged(double preampDb) {
    if (_isDisposed) return;
    if (_preamp == preampDb) return;
    _preamp = preampDb;
    if (!_preampController.isClosed) {
      _preampController.add(preampDb);
    }
  }

  void notifyBalanceChanged(double balance) {
    if (_isDisposed) return;
    if (_balance == balance) return;
    _balance = balance;
    if (!_balanceController.isClosed) {
      _balanceController.add(balance);
    }
  }

  void notifyMonoChanged(bool mono) {
    if (_isDisposed) return;
    if (_mono == mono) return;
    _mono = mono;
    if (!_monoController.isClosed) {
      _monoController.add(mono);
    }
  }

  void notifyCrossfeedChanged(CrossfeedMode crossfeed) {
    if (_isDisposed) return;
    if (_crossfeed == crossfeed) return;
    _crossfeed = crossfeed;
    if (!_crossfeedController.isClosed) {
      _crossfeedController.add(crossfeed);
    }
  }

  void notifySpatializerChanged({required bool enabled, required double width}) {
    if (_isDisposed) return;
    if (_spatializerEnabled != enabled) {
      _spatializerEnabled = enabled;
      if (!_spatializerEnabledController.isClosed) {
        _spatializerEnabledController.add(enabled);
      }
    }
    if (_spatializerWidth != width) {
      _spatializerWidth = width;
      if (!_spatializerWidthController.isClosed) {
        _spatializerWidthController.add(width);
      }
    }
  }

  void notifyLimiterChanged(bool enabled) {
    if (_isDisposed) return;
    if (_limiterEnabled == enabled) return;
    _limiterEnabled = enabled;
    if (!_limiterEnabledController.isClosed) {
      _limiterEnabledController.add(enabled);
    }
  }

  void notifyReverbChanged(Reverb reverb) {
    if (_isDisposed) return;
    if (_reverb == reverb) return;
    _reverb = reverb;
    if (!_reverbController.isClosed) {
      _reverbController.add(reverb);
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

  /// Destroys the player instance and frees native C memory.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    resetMetadata();

    action.dispose();
    _finalizer.detach(this);
    _eventCallable.close();
    _completedCallable.close();

    if (_playerHandle != nullptr) {
      native.miniaudio_player_set_event_callback(
          _playerHandle, nullptr, nullptr);
      native.miniaudio_player_destroy(_playerHandle);
      _playerHandle = nullptr;
    }

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
