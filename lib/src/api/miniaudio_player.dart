import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../equalizer.dart';
import '../ffi/native_types.dart';
import '../isolate/isolate_messages.dart';
import '../isolate/player_isolate_client.dart';
import 'audio_device.dart';
import 'player_action.dart';
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
/// Executes each player instance in a dedicated secondary Dart Isolate,
/// maintaining thread safety and preventing UI thread blocking.
class MiniaudioPlayer {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  /// Global configuration accessor and updater for [MiniaudioPlayer].
  ///
  /// Can be used as `MiniaudioPlayer.config().defaultBufferSize = 1024` or
  /// `MiniaudioPlayer.config(defaultBufferSize: 1024, logLevel: MiniaudioLogLevel.debug, defaultAudioDevice: AudioDevice.auto)`.
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
  ///
  /// If [includeAuto] is `true` (default), [AudioDevice.auto] is included as
  /// the first option in the returned list.
  static Future<List<AudioDevice>> getAudioDevices({
    bool includeAuto = true,
  }) async {
    return await Isolate.run<List<AudioDevice>>(() {
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
    });
  }

  late final PlayerIsolateClient _client;

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

  bool _isDisposed = false;

  /// Action interface for controlling playback, volume, rate, pitch, buffer size, and DSP.
  late final PlayerAction action;

  /// Reactive stream interface for observing state changes.
  late final PlayerStream stream;

  /// Synchronous state snapshot interface.
  late final PlayerState state;

  /// Creates an isolated [MiniaudioPlayer] instance initialized with
  /// [MiniaudioPlayerGlobalConfig.defaultBufferSize] and
  /// [MiniaudioPlayerGlobalConfig.defaultAudioDevice].
  MiniaudioPlayer({int? bufferSize, AudioDevice? defaultAudioDevice}) {
    _bufferSize = bufferSize ?? _globalConfig.defaultBufferSize;
    _audioDevice = defaultAudioDevice ?? _globalConfig.defaultAudioDevice;

    _client = PlayerIsolateClient(
      initialBufferSize: _bufferSize,
      initialLogLevel: _globalConfig.logLevel.value,
      initialDeviceId: _audioDevice.id,
      onStatus: _handleStatusEvent,
      onVolume: _handleVolumeEvent,
      onRate: _handleRateEvent,
      onPitch: _handlePitchEvent,
      onBufferSize: _handleBufferSizeEvent,
      onEqualizer: _handleEqualizerEvent,
      onDevice: _handleDeviceEvent,
      onError: _handleErrorEvent,
    );

    action = PlayerAction(
      _client,
      onOptimisticSeek: (pos) {
        _position = pos;
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

  /// Sets the active audio output device.
  ///
  /// Returns `true` if the device was successfully set, or `false` if the device
  /// was unavailable / disconnected and the player fell back to the default output.
  Future<bool> setDevice(AudioDevice device) => action.setDevice(device);

  void _handleStatusEvent(PlaybackStatusEvent event) {
    if (_isDisposed) return;

    if (event.position != _position) {
      _position = event.position;
      if (!_positionController.isClosed) {
        _positionController.add(_position);
      }
    }

    if (event.duration != _duration) {
      _duration = event.duration;
      if (!_durationController.isClosed) {
        _durationController.add(_duration);
      }
    }

    if (event.isPlaying != _playing) {
      _playing = event.isPlaying;
      if (!_playingController.isClosed) {
        _playingController.add(_playing);
      }
    }

    if (event.isBuffering != _buffering) {
      _buffering = event.isBuffering;
      if (!_bufferingController.isClosed) {
        _bufferingController.add(_buffering);
      }
    }

    if (event.isCompleted != _completed) {
      _completed = event.isCompleted;
      if (!_completedController.isClosed) {
        _completedController.add(_completed);
      }
    }

    if (event.bitrate != _audioBitrate) {
      _audioBitrate = event.bitrate;
      if (!_audioBitrateController.isClosed) {
        _audioBitrateController.add(_audioBitrate);
      }
    }
  }

  void _handleVolumeEvent(double volume) {
    if (_isDisposed) return;
    _volume = volume;
    if (!_volumeController.isClosed) {
      _volumeController.add(volume);
    }
  }

  void _handleRateEvent(double rate) {
    if (_isDisposed) return;
    _rate = rate;
    if (!_rateController.isClosed) {
      _rateController.add(rate);
    }
  }

  void _handlePitchEvent(double pitch) {
    if (_isDisposed) return;
    _pitch = pitch;
    if (!_pitchController.isClosed) {
      _pitchController.add(pitch);
    }
  }

  void _handleBufferSizeEvent(int bufferSize) {
    if (_isDisposed) return;
    _bufferSize = bufferSize;
    if (!_bufferSizeController.isClosed) {
      _bufferSizeController.add(bufferSize);
    }
  }

  void _handleEqualizerEvent(List<double> gainsDb) {
    if (_isDisposed) return;
    _equalizer = Equalizer.fromList(gainsDb);
    if (!_equalizerController.isClosed) {
      _equalizerController.add(_equalizer);
    }
  }

  void _handleDeviceEvent(AudioDevice device) {
    if (_isDisposed) return;
    _audioDevice = device;
    if (!_audioDeviceController.isClosed) {
      _audioDeviceController.add(device);
    }
  }

  void _handleErrorEvent(String message, int? errorCode, String? details) {
    // Errors are logged or dispatched to pending commands
  }

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  /// Current internal buffer size in frames (0 = native default).
  int get bufferSize => _bufferSize;

  /// Current audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  int get audioBitrate => _audioBitrate;

  /// Alias for [audioBitrate].
  int get bitrate => _audioBitrate;

  /// Destroys the player instance, terminates the secondary Isolate, and frees native C memory.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    await _client.dispose();

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
