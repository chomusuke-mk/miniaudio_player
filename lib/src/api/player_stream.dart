// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'audio_device.dart';
import '../equalizer.dart';

/// Reactive broadcast streams for observing playback and DSP state changes.
class PlayerStream {
  final StreamController<Duration> _positionController;
  final StreamController<Duration> _durationController;
  final StreamController<bool> _playingController;
  final StreamController<bool> _bufferingController;
  final StreamController<bool> _completedController;
  final StreamController<double> _volumeController;
  final StreamController<double> _rateController;
  final StreamController<double> _pitchController;
  final StreamController<int> _bufferSizeController;
  final StreamController<int> _audioBitrateController;
  final StreamController<Equalizer> _equalizerController;
  final StreamController<AudioDevice> _audioDeviceController;

  PlayerStream({
    required StreamController<Duration> positionController,
    required StreamController<Duration> durationController,
    required StreamController<bool> playingController,
    required StreamController<bool> bufferingController,
    required StreamController<bool> completedController,
    required StreamController<double> volumeController,
    required StreamController<double> rateController,
    required StreamController<double> pitchController,
    required StreamController<int> bufferSizeController,
    required StreamController<int> audioBitrateController,
    required StreamController<Equalizer> equalizerController,
    required StreamController<AudioDevice> audioDeviceController,
  }) : _positionController = positionController,
       _durationController = durationController,
       _playingController = playingController,
       _bufferingController = bufferingController,
       _completedController = completedController,
       _volumeController = volumeController,
       _rateController = rateController,
       _pitchController = pitchController,
       _bufferSizeController = bufferSizeController,
       _audioBitrateController = audioBitrateController,
       _equalizerController = equalizerController,
       _audioDeviceController = audioDeviceController;

  /// Broadcast stream of the current playback position.
  Stream<Duration> get position => _positionController.stream;

  /// Broadcast stream of total audio duration.
  Stream<Duration> get duration => _durationController.stream;

  /// Broadcast stream of playback state (`true` if playing, `false` otherwise).
  Stream<bool> get playing => _playingController.stream;

  /// Broadcast stream of buffering state.
  Stream<bool> get buffering => _bufferingController.stream;

  /// Broadcast stream of playback completion status.
  Stream<bool> get completed => _completedController.stream;

  /// Broadcast stream of volume level changes.
  Stream<double> get volume => _volumeController.stream;

  /// Broadcast stream of playback speed multiplier changes.
  Stream<double> get rate => _rateController.stream;

  /// Broadcast stream of pitch multiplier changes.
  Stream<double> get pitch => _pitchController.stream;

  /// Broadcast stream of internal buffer size changes in frames.
  Stream<int> get bufferSize => _bufferSizeController.stream;

  /// Broadcast stream of audio bitrate changes in bits per second (bps).
  Stream<int> get audioBitrate => _audioBitrateController.stream;

  /// Alias for [audioBitrate].
  Stream<int> get bitrate => _audioBitrateController.stream;

  /// Broadcast stream of 10-band equalizer configuration changes.
  Stream<Equalizer> get equalizer => _equalizerController.stream;

  /// Broadcast stream of active audio output device changes.
  Stream<AudioDevice> get audioDevice => _audioDeviceController.stream;
}
