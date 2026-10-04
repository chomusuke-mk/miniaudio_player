// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../miniaudio_player_bindings_generated.dart' as native;
import '../equalizer.dart';
import '../ffi/native_types.dart';
import 'audio_device.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final MiniaudioPlayer _player;
  final void Function(Duration position) _onOptimisticSeek;

  PlayerAction(
    this._player, {
    required void Function(Duration) onOptimisticSeek,
  }) : _onOptimisticSeek = onOptimisticSeek;

  /// Prepares an audio file for playback.
  ///
  /// If [autoPlay] is `true`, playback starts immediately upon opening.
  Future<void> open(String filePath, {bool autoPlay = false}) async {
    _player.ensureNotDisposed();
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    final pathPtr = path.toNativeUtf8();
    try {
      final res = native.miniaudio_player_open_file(
        _player.handle,
        pathPtr.cast(),
      );
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to open audio file: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }

      if (autoPlay) {
        final playRes = native.miniaudio_player_play(_player.handle);
        if (playRes != MapResult.success) {
          throw MiniaudioPlayerException(
            'Failed to start playback on autoPlay: ${MapResult.describe(playRes)}',
            errorCode: playRes,
          );
        }
      }

      _player.pollAndEmit(force: true);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_play(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to start playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Pauses audio playback at the current position.
  Future<void> pause() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_pause(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to pause playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    _player.ensureNotDisposed();
    final res = native.miniaudio_player_stop(_player.handle);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to stop playback: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) async {
    _player.ensureNotDisposed();
    _onOptimisticSeek(position);
    final durationMs = native.miniaudio_player_get_duration_ms(_player.handle);
    var targetMs = position.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durationMs > 0 && targetMs > durationMs) {
      targetMs = durationMs;
    }
    final res = native.miniaudio_player_seek(_player.handle, targetMs);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to seek: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.pollAndEmit(force: true);
  }

  /// Sets the audio volume level (default: 1.0, 0.0 to 2.0).
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite) {
      throw ArgumentError.value(volume, 'volume', 'Volume must be finite');
    }
    if (volume < 0.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Volume must be non-negative',
      );
    }
    final clampedVolume = volume.clamp(0.0, 2.0);
    final res = native.miniaudio_player_set_volume(_player.handle, clampedVolume);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set volume: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyVolumeChanged(clampedVolume);
  }

  /// Sets the playback speed multiplier (default: 1.0, 0.1 to 4.0).
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    if (rate.isNaN || rate.isInfinite) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be finite');
    }
    if (rate <= 0.0) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be positive');
    }
    final clampedRate = rate.clamp(0.1, 4.0);
    final res = native.miniaudio_player_set_rate(_player.handle, clampedRate);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set rate: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyRateChanged(clampedRate);
  }

  /// Sets the audio pitch multiplier (default: 1.0, 0.5 to 2.0).
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be finite');
    }
    if (pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be positive');
    }
    final clampedPitch = pitch.clamp(0.5, 2.0);
    final res = native.miniaudio_player_set_pitch(_player.handle, clampedPitch);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set pitch: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    _player.notifyPitchChanged(clampedPitch);
  }

  /// Sets the internal buffer size in frames (0 = native miniaudio default).
  Future<void> setBufferSize(int bufferSize) async {
    _player.ensureNotDisposed();
    if (bufferSize < 0) {
      throw ArgumentError.value(
        bufferSize,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    final res = native.miniaudio_player_set_buffer_size(_player.handle, bufferSize);
    if (res != MapResult.success) {
      throw MiniaudioPlayerException(
        'Failed to set buffer size: ${MapResult.describe(res)}',
        errorCode: res,
      );
    }
    final actualBufferSize = native.miniaudio_player_get_buffer_size(_player.handle);
    _player.notifyBufferSizeChanged(actualBufferSize);
  }

  /// Applies a 10-band [Equalizer] configuration.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player.ensureNotDisposed();
    final gainsDb = equalizer.toList();
    final eqPtr = calloc<native.miniaudio_player_equalizer_params_t>();
    try {
      eqPtr.ref.hz60 = gainsDb[0];
      eqPtr.ref.hz170 = gainsDb[1];
      eqPtr.ref.hz310 = gainsDb[2];
      eqPtr.ref.hz600 = gainsDb[3];
      eqPtr.ref.hz1k = gainsDb[4];
      eqPtr.ref.hz3k = gainsDb[5];
      eqPtr.ref.hz6k = gainsDb[6];
      eqPtr.ref.hz12k = gainsDb[7];
      eqPtr.ref.hz14k = gainsDb[8];
      eqPtr.ref.hz16k = gainsDb[9];

      final res = native.miniaudio_player_set_equalizer(_player.handle, eqPtr);
      if (res != MapResult.success) {
        throw MiniaudioPlayerException(
          'Failed to set equalizer: ${MapResult.describe(res)}',
          errorCode: res,
        );
      }
      _player.notifyEqualizerChanged(equalizer);
    } finally {
      calloc.free(eqPtr);
    }
  }

  /// Sets the active audio output device.
  ///
  /// Returns `true` if the device was successfully set, or `false` if the device
  /// was unavailable / disconnected and the player fell back to the default output.
  ///
  /// Supports [AudioDevice.auto] for automatic system default routing, or any
  /// [AudioDevice] obtained via [MiniaudioPlayer.getAudioDevices].
  Future<bool> setDevice(AudioDevice device) async {
    _player.ensureNotDisposed();
    final isAutoTarget = device.isAuto ||
        device.id.isEmpty ||
        device.id == 'auto' ||
        device.id == 'default' ||
        device.id == '0';
    Pointer<Utf8>? devIdPtr;
    if (!isAutoTarget) {
      devIdPtr = device.id.toNativeUtf8();
    }
    try {
      final res = native.miniaudio_player_set_device(
        _player.handle,
        devIdPtr != null ? devIdPtr.cast() : nullptr,
      );
      final devPtr = calloc<native.miniaudio_device_info_t>();
      bool success = res == MapResult.success;
      try {
        if (native.miniaudio_player_get_current_device(_player.handle, devPtr) ==
            MapResult.success) {
          final activeDev = devPtr.ref.toAudioDevice();
          var eventDev = activeDev;
          if (!isAutoTarget &&
              activeDev.id == device.id &&
              device.name.isNotEmpty) {
            eventDev = AudioDevice(
              id: activeDev.id,
              name: device.name,
              isDefault: device.isDefault,
              isAuto: false,
              type: device.type,
            );
          }
          _player.notifyDeviceChanged(eventDev);
          if (isAutoTarget) {
            success = activeDev.isAuto;
          } else {
            success = !activeDev.isAuto && activeDev.id == device.id;
          }
        } else if (!success) {
          throw MiniaudioPlayerException(
            'Failed to set audio device: ${MapResult.describe(res)}',
            errorCode: res,
          );
        }
      } finally {
        calloc.free(devPtr);
      }
      return success;
    } finally {
      if (devIdPtr != null) calloc.free(devIdPtr);
    }
  }
}
