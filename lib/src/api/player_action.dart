// ignore_for_file: prefer_initializing_formals

import 'audio_device.dart';
import '../equalizer.dart';
import '../isolate/isolate_messages.dart';
import '../isolate/player_isolate_client.dart';

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final PlayerIsolateClient _client;
  final void Function(Duration position) _onOptimisticSeek;

  PlayerAction(
    this._client, {
    required void Function(Duration) onOptimisticSeek,
  }) : _onOptimisticSeek = onOptimisticSeek;

  /// Prepares an audio file for playback.
  ///
  /// If [autoPlay] is `true`, playback starts immediately upon opening.
  Future<void> open(String filePath, {bool autoPlay = false}) async {
    await _client.sendCommand<dynamic>(
      (id) => OpenCommand(id, filePath, autoPlay: autoPlay),
    );
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    await _client.sendCommand<void>((id) => PlayCommand(id));
  }

  /// Pauses audio playback at the current position.
  Future<void> pause() async {
    await _client.sendCommand<void>((id) => PauseCommand(id));
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    await _client.sendCommand<void>((id) => StopCommand(id));
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) async {
    _onOptimisticSeek(position);
    await _client.sendCommand<void>((id) => SeekCommand(id, position));
  }

  /// Sets the audio volume level (default: 1.0, 0.0 to 2.0).
  Future<void> setVolume(double volume) async {
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
    await _client.sendCommand<void>(
      (id) => SetVolumeCommand(id, clampedVolume),
    );
  }

  /// Sets the playback speed multiplier (default: 1.0, 0.1 to 4.0).
  Future<void> setRate(double rate) async {
    if (rate.isNaN || rate.isInfinite) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be finite');
    }
    if (rate <= 0.0) {
      throw ArgumentError.value(rate, 'rate', 'Playback rate must be positive');
    }
    final clampedRate = rate.clamp(0.1, 4.0);
    await _client.sendCommand<void>((id) => SetRateCommand(id, clampedRate));
  }

  /// Sets the audio pitch multiplier (default: 1.0, 0.5 to 2.0).
  Future<void> setPitch(double pitch) async {
    if (pitch.isNaN || pitch.isInfinite) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be finite');
    }
    if (pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be positive');
    }
    final clampedPitch = pitch.clamp(0.5, 2.0);
    await _client.sendCommand<void>((id) => SetPitchCommand(id, clampedPitch));
  }

  /// Sets the internal buffer size in frames (0 = native miniaudio default).
  Future<void> setBufferSize(int bufferSize) async {
    if (bufferSize < 0) {
      throw ArgumentError.value(
        bufferSize,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    await _client.sendCommand<void>(
      (id) => SetBufferSizeCommand(id, bufferSize),
    );
  }

  /// Applies a 10-band [Equalizer] configuration.
  Future<void> setEqualizer(Equalizer equalizer) async {
    await _client.sendCommand<void>(
      (id) => SetEqualizerCommand(id, equalizer.toList()),
    );
  }

  /// Sets the active audio output device.
  ///
  /// Returns `true` if the device was successfully set, or `false` if the device
  /// was unavailable / disconnected and the player fell back to the default output.
  ///
  /// Supports [AudioDevice.auto] for automatic system default routing, or any
  /// [AudioDevice] obtained via [MiniaudioPlayer.getAudioDevices].
  Future<bool> setDevice(AudioDevice device) {
    return _client.sendCommand<bool>((id) => SetDeviceCommand(id, device));
  }
}
