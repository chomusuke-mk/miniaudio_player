import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../api/audio_device.dart';
import '../ffi/native_types.dart';
import 'isolate_messages.dart';

/// Periodic status emitter that queries the native miniaudio player snapshot
/// at a fixed frequency (default 50ms / 20Hz), applying delta thresholding
/// to avoid flooding the Flutter UI event loop.
class ThrottledEmitter {
  final Pointer<native.miniaudio_player_t> playerHandle;
  final SendPort sendPort;
  final Duration interval;
  final Duration positionDeltaThreshold;

  Timer? _timer;
  Pointer<native.miniaudio_player_status_t>? _statusPtr;
  bool _isDisposed = false;

  Duration? _lastPosition;
  Duration? _lastDuration;
  bool? _lastIsPlaying;
  bool? _lastIsBuffering;
  bool? _lastIsCompleted;
  int? _lastState;
  int? _lastBitrate;
  AudioDevice? _lastDevice;

  ThrottledEmitter({
    required this.playerHandle,
    required this.sendPort,
    this.interval = const Duration(milliseconds: 50),
    this.positionDeltaThreshold = Duration.zero,
  }) {
    _statusPtr = calloc<native.miniaudio_player_status_t>();
  }

  bool get isActive => _timer != null && _timer!.isActive;
  bool get isDisposed => _isDisposed;

  void start() {
    if (_isDisposed || playerHandle == nullptr) return;
    if (_timer != null && _timer!.isActive) return;

    _timer = Timer.periodic(interval, (_) => _onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _onTick() {
    if (_isDisposed || playerHandle == nullptr) {
      stop();
      return;
    }

    pollAndEmit(force: false);
  }

  bool pollAndEmit({bool force = false}) {
    if (_isDisposed || _statusPtr == null || playerHandle == nullptr) {
      return false;
    }

    final res = native.miniaudio_player_get_status(playerHandle, _statusPtr!);
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
      sendPort.send(AudioDeviceChangedEvent(device));
    }

    final bool stateChanged =
        isPlaying != _lastIsPlaying ||
        isBuffering != _lastIsBuffering ||
        isCompleted != _lastIsCompleted ||
        state != _lastState ||
        duration != _lastDuration ||
        bitrate != _lastBitrate;

    final bool positionChanged;
    if (_lastPosition == null) {
      positionChanged = true;
    } else if (positionDeltaThreshold == Duration.zero) {
      positionChanged = position != _lastPosition;
    } else {
      positionChanged =
          (position - _lastPosition!).abs() > positionDeltaThreshold;
    }

    if (!force && !stateChanged && !positionChanged) {
      return false;
    }

    _lastPosition = position;
    _lastDuration = duration;
    _lastIsPlaying = isPlaying;
    _lastIsBuffering = isBuffering;
    _lastIsCompleted = isCompleted;
    _lastState = state;
    _lastBitrate = bitrate;

    sendPort.send(
      PlaybackStatusEvent(
        position: position,
        duration: duration,
        isPlaying: isPlaying,
        isBuffering: isBuffering,
        isCompleted: isCompleted,
        state: state,
        bitrate: bitrate,
      ),
    );

    return true;
  }

  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    stop();
    if (_statusPtr != null) {
      calloc.free(_statusPtr!);
      _statusPtr = null;
    }
  }
}
