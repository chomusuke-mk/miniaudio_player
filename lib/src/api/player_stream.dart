// ignore_for_file: prefer_initializing_formals

import 'dart:async';

import 'audio_device.dart';
import 'buffered_range.dart';
import 'dsp_config.dart';
import 'silence_skip_config.dart';
import 'track_metadata.dart';
import 'visualizer_data.dart';
import '../equalizer.dart';
import '../reverb.dart';

/// Reactive broadcast streams for observing playback and DSP state changes.
class PlayerStream {
  final StreamController<Duration> _positionController;
  final StreamController<Duration> _durationController;
  final StreamController<bool> _playingController;
  final StreamController<bool> _bufferingController;
  final StreamController<bool> _completedController;
  final StreamController<Duration> _bufferedPositionController;
  final StreamController<double> _bufferedPercentageController;
  final StreamController<BufferedRange> _bufferedRangeController;
  final StreamController<AudioTrackMetadata?> _trackMetadataController;
  final StreamController<double> _volumeController;
  final StreamController<double> _rateController;
  final StreamController<double> _pitchController;
  final StreamController<int> _bufferSizeController;
  final StreamController<int> _audioBitrateController;
  final StreamController<Equalizer> _equalizerController;
  final StreamController<AudioDevice> _audioDeviceController;
  final StreamController<bool> _skipSilenceController;
  final StreamController<SilenceSkipConfig> _silenceConfigController;
  final StreamController<Duration> _silenceSavedDurationController;
  final StreamController<VisualizerData> _visualizerController;
  final StreamController<bool> _visualizerEnabledController;
  final StreamController<double> _preampController;
  final StreamController<ReplayGainConfig> _replayGainController;
  final StreamController<double> _balanceController;
  final StreamController<bool> _monoController;
  final StreamController<CrossfeedMode> _crossfeedController;
  final StreamController<bool> _spatializerEnabledController;
  final StreamController<double> _spatializerWidthController;
  final StreamController<Reverb> _reverbController;
  final StreamController<bool> _limiterEnabledController;

  PlayerStream({
    required StreamController<Duration> positionController,
    required StreamController<Duration> durationController,
    required StreamController<bool> playingController,
    required StreamController<bool> bufferingController,
    required StreamController<bool> completedController,
    required StreamController<Duration> bufferedPositionController,
    required StreamController<double> bufferedPercentageController,
    required StreamController<BufferedRange> bufferedRangeController,
    required StreamController<AudioTrackMetadata?> trackMetadataController,
    required StreamController<double> volumeController,
    required StreamController<double> rateController,
    required StreamController<double> pitchController,
    required StreamController<int> bufferSizeController,
    required StreamController<int> audioBitrateController,
    required StreamController<Equalizer> equalizerController,
    required StreamController<AudioDevice> audioDeviceController,
    required StreamController<bool> skipSilenceController,
    required StreamController<SilenceSkipConfig> silenceConfigController,
    required StreamController<Duration> silenceSavedDurationController,
    required StreamController<VisualizerData> visualizerController,
    required StreamController<bool> visualizerEnabledController,
    required StreamController<double> preampController,
    required StreamController<ReplayGainConfig> replayGainController,
    required StreamController<double> balanceController,
    required StreamController<bool> monoController,
    required StreamController<CrossfeedMode> crossfeedController,
    required StreamController<bool> spatializerEnabledController,
    required StreamController<double> spatializerWidthController,
    required StreamController<Reverb> reverbController,
    required StreamController<bool> limiterEnabledController,
  })  : _positionController = positionController,
        _durationController = durationController,
        _playingController = playingController,
        _bufferingController = bufferingController,
        _completedController = completedController,
        _bufferedPositionController = bufferedPositionController,
        _bufferedPercentageController = bufferedPercentageController,
        _bufferedRangeController = bufferedRangeController,
        _trackMetadataController = trackMetadataController,
        _volumeController = volumeController,
        _rateController = rateController,
        _pitchController = pitchController,
        _bufferSizeController = bufferSizeController,
        _audioBitrateController = audioBitrateController,
        _equalizerController = equalizerController,
        _audioDeviceController = audioDeviceController,
        _skipSilenceController = skipSilenceController,
        _silenceConfigController = silenceConfigController,
        _silenceSavedDurationController = silenceSavedDurationController,
        _visualizerController = visualizerController,
        _visualizerEnabledController = visualizerEnabledController,
        _preampController = preampController,
        _replayGainController = replayGainController,
        _balanceController = balanceController,
        _monoController = monoController,
        _crossfeedController = crossfeedController,
        _spatializerEnabledController = spatializerEnabledController,
        _spatializerWidthController = spatializerWidthController,
        _reverbController = reverbController,
        _limiterEnabledController = limiterEnabledController;

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

  /// Broadcast stream of furthest continuous timestamp preloaded in RAM buffer.
  Stream<Duration> get bufferedPosition => _bufferedPositionController.stream;

  /// Broadcast stream of fraction (0.0 to 1.0) of track loaded (for preloaded bar).
  Stream<double> get bufferedPercentage => _bufferedPercentageController.stream;

  /// Broadcast stream of sliding-window circular buffer telemetry metrics.
  Stream<BufferedRange> get bufferedRange => _bufferedRangeController.stream;

  /// Broadcast stream of current track metadata.
  Stream<AudioTrackMetadata?> get trackMetadata => _trackMetadataController.stream;

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

  /// Broadcast stream of silence skipping enabled state (`true` / `false`).
  Stream<bool> get skipSilence => _skipSilenceController.stream;

  /// Broadcast stream of silence configuration changes.
  Stream<SilenceSkipConfig> get silenceConfig => _silenceConfigController.stream;

  /// Broadcast stream of cumulative duration of skipped silence.
  Stream<Duration> get silenceSavedDuration =>
      _silenceSavedDurationController.stream;

  /// Broadcast stream of real-time audio visualizer data (10 bands matching equalizer + volume metrics).
  Stream<VisualizerData> get visualizer => _visualizerController.stream;

  /// Broadcast stream of visualizer active / enabled state changes.
  Stream<bool> get visualizerEnabled => _visualizerEnabledController.stream;

  /// Broadcast stream of manual preamp gain changes.
  Stream<double> get preamp => _preampController.stream;

  /// Broadcast stream of ReplayGain configuration changes.
  Stream<ReplayGainConfig> get replayGain => _replayGainController.stream;

  /// Broadcast stream of stereo balance changes.
  Stream<double> get balance => _balanceController.stream;

  /// Broadcast stream of mono downmix status changes.
  Stream<bool> get mono => _monoController.stream;

  /// Broadcast stream of headphone crossfeed mode changes.
  Stream<CrossfeedMode> get crossfeed => _crossfeedController.stream;

  /// Broadcast stream of stereo widener enabled changes.
  Stream<bool> get spatializerEnabled => _spatializerEnabledController.stream;

  /// Broadcast stream of stereo widener width factor changes.
  Stream<double> get spatializerWidth => _spatializerWidthController.stream;

  /// Broadcast stream of reverb configuration changes.
  Stream<Reverb> get reverb => _reverbController.stream;

  /// Broadcast stream of limiter enabled changes.
  Stream<bool> get limiterEnabled => _limiterEnabledController.stream;
}
