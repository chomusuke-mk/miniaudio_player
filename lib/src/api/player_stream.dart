import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffer.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'loop_mode.dart';
import 'need_more_tracks_event.dart';
import 'player_exception.dart';
import 'player_models.dart';
import 'player_state.dart' show EnginePhase, PlaybackState;
import 'silence_skip_config.dart';
import 'visualizer_data.dart';

/// Reactive broadcast streams for observing playback, queue, effects, and DSP state changes.
///
/// In strict accordance with the stream-driven architecture, events originate from the native
/// Rust event pipeline and are dispatched to UI observers without artificial intermediate filtering.
class PlayerStream<T> {
  final StreamController<Duration> positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration?> durationController =
      StreamController<Duration?>.broadcast();
  final StreamController<bool> playingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> bufferingController =
      StreamController<bool>.broadcast();
  final StreamController<bool> completedController =
      StreamController<bool>.broadcast();
  final StreamController<bool> openingController =
      StreamController<bool>.broadcast();
  final StreamController<PlaybackState> playbackStateController =
      StreamController<PlaybackState>.broadcast();
  final StreamController<EnginePhase> phaseController =
      StreamController<EnginePhase>.broadcast();
  final StreamController<Buffer> bufferController =
      StreamController<Buffer>.broadcast();
  final StreamController<Uint8List?> metaBytesController =
      StreamController<Uint8List?>.broadcast();
  final StreamController<bool> metaBytesEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<int> sampleRateController =
      StreamController<int>.broadcast();
  final StreamController<int> channelsController =
      StreamController<int>.broadcast();
  final StreamController<double> volumeController =
      StreamController<double>.broadcast();
  final StreamController<double> rateController =
      StreamController<double>.broadcast();
  final StreamController<double> pitchController =
      StreamController<double>.broadcast();
  final StreamController<double> balanceController =
      StreamController<double>.broadcast();
  final StreamController<bool> monoController =
      StreamController<bool>.broadcast();
  final StreamController<int> bufferSizeController =
      StreamController<int>.broadcast();
  final StreamController<int> audioBitrateController =
      StreamController<int>.broadcast();
  final StreamController<Equalizer> equalizerController =
      StreamController<Equalizer>.broadcast();
  final StreamController<AudioDevice> audioDeviceController =
      StreamController<AudioDevice>.broadcast();
  final StreamController<Set<AudioOutput>> outputsController =
      StreamController<Set<AudioOutput>>.broadcast();
  final StreamController<Set<AudioInput>> inputsController =
      StreamController<Set<AudioInput>>.broadcast();
  final StreamController<List<AudioDevice>> globalOutputDevicesController =
      StreamController<List<AudioDevice>>.broadcast();
  final StreamController<List<AudioDevice>> globalInputDevicesController =
      StreamController<List<AudioDevice>>.broadcast();
  final StreamController<bool> pauseOnDeviceChangeController =
      StreamController<bool>.broadcast();
  final StreamController<bool> skipSilenceController =
      StreamController<bool>.broadcast();
  final StreamController<SilenceSkipConfig> silenceConfigController =
      StreamController<SilenceSkipConfig>.broadcast();
  final StreamController<Duration> silenceSavedDurationController =
      StreamController<Duration>.broadcast();
  final StreamController<VisualizerData> visualizerController =
      StreamController<VisualizerData>.broadcast();
  final StreamController<bool> visualizerEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> preampController =
      StreamController<double>.broadcast();
  final StreamController<ReplayGainConfig> replayGainController =
      StreamController<ReplayGainConfig>.broadcast();
  final StreamController<CrossfeedMode> crossfeedController =
      StreamController<CrossfeedMode>.broadcast();
  final StreamController<bool> spatializerEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> spatializerWidthController =
      StreamController<double>.broadcast();
  final StreamController<Reverb> reverbController =
      StreamController<Reverb>.broadcast();
  final StreamController<bool> limiterEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<List<AudioSource<T>>> queueController =
      StreamController<List<AudioSource<T>>>.broadcast();
  final StreamController<int> currentIndexController =
      StreamController<int>.broadcast();
  final StreamController<AudioSource<T>?> currentItemController =
      StreamController<AudioSource<T>?>.broadcast();
  final StreamController<LoopMode> loopModeController =
      StreamController<LoopMode>.broadcast();
  final StreamController<bool> isShuffledController =
      StreamController<bool>.broadcast();
  final StreamController<bool> isCrossfadingController =
      StreamController<bool>.broadcast();
  final StreamController<CrossfadeConfig> crossfadeConfigController =
      StreamController<CrossfadeConfig>.broadcast();
  final StreamController<bool> isRecordingController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> recordedDurationController =
      StreamController<Duration>.broadcast();
  final StreamController<double> cueVolumeController =
      StreamController<double>.broadcast();
  final StreamController<CueSource> cueSourceController =
      StreamController<CueSource>.broadcast();
  final StreamController<bool> isMicrophoneEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> micVolumeController =
      StreamController<double>.broadcast();
  final StreamController<bool> isDuckingActiveController =
      StreamController<bool>.broadcast();
  final StreamController<bool> isDirectMonitoringEnabledController =
      StreamController<bool>.broadcast();
  final StreamController<double> micRmsLevelController =
      StreamController<double>.broadcast();
  final StreamController<VoiceId> voiceCompletedController =
      StreamController<VoiceId>.broadcast();
  final StreamController<int> activeVoicesCountController =
      StreamController<int>.broadcast();
  final StreamController<int> allocatedRamBytesController =
      StreamController<int>.broadcast();
  final StreamController<List<String>> loadedEffectIdsController =
      StreamController<List<String>>.broadcast();
  final StreamController<MiniaudioPlayerException> errorsController =
      StreamController<MiniaudioPlayerException>.broadcast();
  final StreamController<NeedMoreTracksEvent> needMoreTracksController =
      StreamController<NeedMoreTracksEvent>.broadcast();

  PlayerStream();

  Stream<Duration> get position => positionController.stream;
  Stream<Duration?> get duration => durationController.stream;
  Stream<bool> get playing => playingController.stream;
  Stream<bool> get isPlaying => playingController.stream;
  Stream<bool> get buffering => bufferingController.stream;
  Stream<bool> get completed => completedController.stream;
  Stream<bool> get opening => openingController.stream;
  Stream<PlaybackState> get playbackState => playbackStateController.stream;
  Stream<EnginePhase> get phase => phaseController.stream;
  Stream<Buffer> get buffer => bufferController.stream;

  /// Reactive broadcast stream emitting raw metadata bytes extracted by the native audio engine
  /// (e.g. ID3, Vorbis, ICY stream metadata).
  ///
  /// Note: In Dart, this stream is always open and ready for listeners, but events are ONLY
  /// emitted through this stream when [metaBytesEnabled] is set to `true`
  /// (via `player.action.setMetaBytesEnabled(true)`).
  /// By default, [metaBytesEnabled] is `false` to avoid saturating the event bus.
  Stream<Uint8List?> get metaBytes => metaBytesController.stream;

  /// Reactive broadcast stream emitting updates whenever metadata dispatch is enabled or disabled.
  Stream<bool> get metaBytesEnabled => metaBytesEnabledController.stream;

  /// Reactive broadcast stream emitting the native sample rate (Hz) of the active playback.
  Stream<int> get sampleRate => sampleRateController.stream;

  /// Reactive broadcast stream emitting the channel count (e.g. 1 for mono, 2 for stereo) of the active playback.
  Stream<int> get channels => channelsController.stream;
  Stream<double> get volume => volumeController.stream;
  Stream<double> get rate => rateController.stream;
  Stream<double> get pitch => pitchController.stream;
  Stream<double> get balance => balanceController.stream;
  Stream<bool> get mono => monoController.stream;
  Stream<int> get bufferSize => bufferSizeController.stream;
  Stream<int> get bitrate => audioBitrateController.stream;
  Stream<int> get audioBitrate => audioBitrateController.stream;
  Stream<Equalizer> get equalizer => equalizerController.stream;
  Stream<AudioDevice> get audioDevice => audioDeviceController.stream;

  /// Reactive broadcast stream emitting this player's active output destinations.
  Stream<Set<AudioOutput>> get outputs => outputsController.stream;

  /// Reactive broadcast stream emitting this player's active input sources.
  Stream<Set<AudioInput>> get inputs => inputsController.stream;

  /// Reactive broadcast stream emitting updates to the global system output devices list.
  Stream<List<AudioDevice>> get globalOutputDevices =>
      globalOutputDevicesController.stream;

  /// Reactive broadcast stream emitting updates to the global system input devices list.
  Stream<List<AudioDevice>> get globalInputDevices =>
      globalInputDevicesController.stream;
  Stream<bool> get pauseOnDeviceChange => pauseOnDeviceChangeController.stream;
  Stream<bool> get skipSilence => skipSilenceController.stream;
  Stream<SilenceSkipConfig> get silenceConfig => silenceConfigController.stream;
  Stream<Duration> get silenceSavedDuration =>
      silenceSavedDurationController.stream;
  /// Reactive broadcast stream emitting real-time 10-band FFT spectrum visualizer metrics.
  ///
  /// Note: In Dart, this stream is always open and ready for listeners, but for events
  /// to actually be computed and emitted here, the visualizer must be activated by setting
  /// [visualizerEnabled] to `true` (via `player.action.setVisualizerEnabled(true)`).
  /// By default, [visualizerEnabled] is `false`.
  Stream<VisualizerData> get visualizer => visualizerController.stream;

  /// Reactive broadcast stream emitting updates whenever the visualizer DSP calculation is enabled or disabled.
  Stream<bool> get visualizerEnabled => visualizerEnabledController.stream;
  Stream<double> get preamp => preampController.stream;
  Stream<ReplayGainConfig> get replayGain => replayGainController.stream;
  Stream<CrossfeedMode> get crossfeed => crossfeedController.stream;
  Stream<bool> get spatializerEnabled => spatializerEnabledController.stream;
  Stream<double> get spatializerWidth => spatializerWidthController.stream;
  Stream<Reverb> get reverb => reverbController.stream;
  Stream<bool> get limiterEnabled => limiterEnabledController.stream;
  Stream<List<AudioSource<T>>> get queue => queueController.stream;
  Stream<int> get currentIndex => currentIndexController.stream;
  Stream<AudioSource<T>?> get currentItem => currentItemController.stream;
  Stream<LoopMode> get loopMode => loopModeController.stream;
  Stream<bool> get isShuffled => isShuffledController.stream;
  Stream<bool> get isCrossfading => isCrossfadingController.stream;
  Stream<CrossfadeConfig> get crossfadeConfig => crossfadeConfigController.stream;
  Stream<bool> get isRecording => isRecordingController.stream;
  Stream<Duration> get recordedDuration => recordedDurationController.stream;
  Stream<double> get cueVolume => cueVolumeController.stream;
  Stream<CueSource> get cueSource => cueSourceController.stream;
  Stream<bool> get isMicrophoneEnabled => isMicrophoneEnabledController.stream;
  Stream<double> get micVolume => micVolumeController.stream;
  Stream<bool> get isDuckingActive => isDuckingActiveController.stream;
  Stream<bool> get isDirectMonitoringEnabled =>
      isDirectMonitoringEnabledController.stream;
  Stream<double> get micRmsLevel => micRmsLevelController.stream;
  Stream<VoiceId> get voiceCompleted => voiceCompletedController.stream;
  Stream<int> get activeVoicesCount => activeVoicesCountController.stream;
  Stream<int> get allocatedRamBytes => allocatedRamBytesController.stream;
  Stream<List<String>> get loadedEffectIds => loadedEffectIdsController.stream;
  Stream<MiniaudioPlayerException> get errors => errorsController.stream;
  Stream<NeedMoreTracksEvent> get needMoreTracks =>
      needMoreTracksController.stream;

  Future<void> dispose() async {
    await Future.wait([
      positionController.close(),
      durationController.close(),
      playingController.close(),
      bufferingController.close(),
      completedController.close(),
      openingController.close(),
      playbackStateController.close(),
      phaseController.close(),
      bufferController.close(),
      activeVoicesCountController.close(),
      allocatedRamBytesController.close(),
      loadedEffectIdsController.close(),
      metaBytesController.close(),
      metaBytesEnabledController.close(),
      sampleRateController.close(),
      channelsController.close(),
      volumeController.close(),
      rateController.close(),
      pitchController.close(),
      balanceController.close(),
      monoController.close(),
      bufferSizeController.close(),
      audioBitrateController.close(),
      equalizerController.close(),
      audioDeviceController.close(),
      outputsController.close(),
      inputsController.close(),
      globalOutputDevicesController.close(),
      globalInputDevicesController.close(),
      pauseOnDeviceChangeController.close(),
      skipSilenceController.close(),
      silenceConfigController.close(),
      silenceSavedDurationController.close(),
      visualizerController.close(),
      visualizerEnabledController.close(),
      preampController.close(),
      replayGainController.close(),
      crossfeedController.close(),
      spatializerEnabledController.close(),
      spatializerWidthController.close(),
      reverbController.close(),
      limiterEnabledController.close(),
      queueController.close(),
      currentIndexController.close(),
      currentItemController.close(),
      loopModeController.close(),
      isShuffledController.close(),
      isCrossfadingController.close(),
      crossfadeConfigController.close(),
      isRecordingController.close(),
      recordedDurationController.close(),
      cueVolumeController.close(),
      cueSourceController.close(),
      isMicrophoneEnabledController.close(),
      micVolumeController.close(),
      isDuckingActiveController.close(),
      isDirectMonitoringEnabledController.close(),
      micRmsLevelController.close(),
      voiceCompletedController.close(),
      errorsController.close(),
      needMoreTracksController.close(),
    ]);
  }
}
