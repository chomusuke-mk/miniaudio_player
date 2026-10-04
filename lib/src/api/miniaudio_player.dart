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

  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
    this.defaultAudioDevice = AudioDevice.auto,
  });
}

/// Cross-platform, ultra-low-resource audio player for Flutter.
///
/// Directly connects to the native C miniaudio engine without Dart Isolates,
/// utilizing native audio threads for real-time decoding, DSP, and playback.
class MiniaudioPlayer {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  /// Global configuration accessor and updater for [MiniaudioPlayer].
  static MiniaudioPlayerGlobalConfig config({
    int? defaultBufferSize,
    MiniaudioLogLevel? logLevel,
    AudioDevice? defaultAudioDevice,
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
    return _globalConfig;
  }

  /// Enumerates all available native playback audio devices on the system.
  static Future<List<AudioDevice>> getAudioDevices({
    bool includeAuto = true,
  }) async {
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

      if (devicesPtr != nullptr) {
        for (var i = 0; i < count; i++) {
          final devC = devicesPtr[i];
          hardwareDevices.add(devC.toAudioDevice());
        }
        native.miniaudio_player_free_devices(devicesPtr, count);
      }

      final result = <AudioDevice>[];

      if (includeAuto) {
        AudioDevice? defaultHardwareDev;
        for (final dev in hardwareDevices) {
          if (dev.isDefault) {
            defaultHardwareDev = dev;
            break;
          }
        }
        defaultHardwareDev ??= hardwareDevices.isNotEmpty
            ? hardwareDevices.first
            : null;

        final autoName = defaultHardwareDev != null
            ? defaultHardwareDev.name
            : 'Default';

        result.add(
          AudioDevice(id: '', name: autoName, isDefault: true, isAuto: true),
        );
      }

      result.addAll(hardwareDevices);
      return result;
    } finally {
      calloc.free(outDevicesPtr);
      calloc.free(outCountPtr);
    }
  }

  Pointer<native.miniaudio_player_t> _playerHandle = nullptr;
  Pointer<native.miniaudio_player_status_t>? _statusPtr;
  late final NativeCallable<native.miniaudio_player_completed_cbFunction> _completedCallable;

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

  // Previous status cache for change detection
  Duration? _lastPosition;
  Duration? _lastDuration;
  bool? _lastIsPlaying;
  bool? _lastIsBuffering;
  bool? _lastIsCompleted;
  int? _lastState;
  int? _lastBitrate;
  AudioDevice? _lastDevice;

  bool _isDisposed = false;

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

    if (_globalConfig.logLevel.value > 0) {
      try {
        native.miniaudio_player_set_log_level(_globalConfig.logLevel.value);
      } catch (_) {}
    }

    _completedCallable = NativeCallable<native.miniaudio_player_completed_cbFunction>.listener(_onNativeCompleted);

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
      getAudioDevice: () => _audioDevice,
    );
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

  void _onNativeCompleted(Pointer<Void> _) {
    if (_isDisposed) return;
    _stopPositionTimer();
    _playing = false;
    _completed = true;
    _lastIsPlaying = false;
    _lastIsCompleted = true;
    _position = _duration;
    _lastPosition = _duration;

    if (!_playingController.isClosed) {
      _playingController.add(false);
    }
    if (!_completedController.isClosed) {
      _completedController.add(true);
    }
    if (!_positionController.isClosed) {
      _positionController.add(_duration);
    }
  }

  void _startPositionTimer() {
    if (_positionTimer != null && _positionTimer!.isActive) return;
    _positionTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
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

    final bool deviceChanged =
        _lastDevice == null ||
        _lastDevice!.id != device.id ||
        _lastDevice!.name != device.name ||
        _lastDevice!.isDefault != device.isDefault ||
        _lastDevice!.isAuto != device.isAuto;

    if (deviceChanged) {
      _lastDevice = device;
      _audioDevice = device;
      if (!_audioDeviceController.isClosed) {
        _audioDeviceController.add(device);
      }
    }

    final bool stateChanged =
        isPlaying != _lastIsPlaying ||
        isBuffering != _lastIsBuffering ||
        isCompleted != _lastIsCompleted ||
        state != _lastState;

    if (stateChanged || force) {
      _lastIsPlaying = isPlaying;
      _lastIsBuffering = isBuffering;
      _lastIsCompleted = isCompleted;
      _lastState = state;
      _playing = isPlaying;
      _buffering = isBuffering;
      _completed = isCompleted;

      if (!_playingController.isClosed) {
        _playingController.add(isPlaying);
      }
      if (!_bufferingController.isClosed) {
        _bufferingController.add(isBuffering);
      }
      if (!_completedController.isClosed) {
        _completedController.add(isCompleted);
      }

      if (isPlaying) {
        _startPositionTimer();
      } else {
        _stopPositionTimer();
      }
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
  }
}
