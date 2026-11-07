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

  /// Creates a [PlayerStream] container with broadcast stream controllers.
  PlayerStream();

  /// Broadcast stream emitting the playback position within the active track.
  Stream<Duration> get position => positionController.stream;

  /// Broadcast stream emitting the duration of the active track, or `null` if live or unbounded.
  Stream<Duration?> get duration => durationController.stream;

  /// Broadcast stream emitting whether audio frames are actively rendering.
  Stream<bool> get playing => playingController.stream;

  /// Broadcast stream emitting whether audio frames are actively rendering (convenience alias for [playing]).
  Stream<bool> get isPlaying => playingController.stream;

  /// Broadcast stream emitting whether playback is stalled waiting for data.
  Stream<bool> get buffering => bufferingController.stream;

  /// Broadcast stream emitting whether track playback has completed.
  Stream<bool> get completed => completedController.stream;

  /// Broadcast stream emitting whether a track is currently opening or resolving.
  Stream<bool> get opening => openingController.stream;

  /// Broadcast stream emitting high-level playback state changes.
  Stream<PlaybackState> get playbackState => playbackStateController.stream;

  /// Broadcast stream emitting explicit FSM engine phase transitions.
  Stream<EnginePhase> get phase => phaseController.stream;

  /// Broadcast stream emitting audio prefetch buffer metrics.
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

  /// Broadcast stream emitting master volume updates (`0.0` to `2.0`).
  Stream<double> get volume => volumeController.stream;

  /// Broadcast stream emitting playback rate multiplier updates (`0.5` to `2.0`).
  Stream<double> get rate => rateController.stream;

  /// Broadcast stream emitting pitch shift multiplier updates (`0.5` to `2.0`).
  Stream<double> get pitch => pitchController.stream;

  /// Broadcast stream emitting stereo balance panning updates (`-1.0` to `1.0`).
  Stream<double> get balance => balanceController.stream;

  /// Broadcast stream emitting mono downmix state updates.
  Stream<bool> get mono => monoController.stream;

  /// Broadcast stream emitting audio buffer frame size updates.
  Stream<int> get bufferSize => bufferSizeController.stream;

  /// Broadcast stream emitting audio stream bitrate updates in bits per second.
  Stream<int> get bitrate => audioBitrateController.stream;

  /// Broadcast stream emitting audio stream bitrate updates in bits per second (alias for [bitrate]).
  Stream<int> get audioBitrate => audioBitrateController.stream;

  /// Broadcast stream emitting 10-band equalizer configuration updates.
  Stream<Equalizer> get equalizer => equalizerController.stream;

  /// Broadcast stream emitting active primary audio device changes.
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

  /// Broadcast stream emitting whether playback automatically pauses on output device disconnect.
  Stream<bool> get pauseOnDeviceChange => pauseOnDeviceChangeController.stream;

  /// Broadcast stream emitting whether silence skipping is enabled.
  Stream<bool> get skipSilence => skipSilenceController.stream;

  /// Broadcast stream emitting silence skipping configuration updates.
  Stream<SilenceSkipConfig> get silenceConfig => silenceConfigController.stream;

  /// Broadcast stream emitting cumulative playback time saved by skipping silence.
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

  /// Broadcast stream emitting master pre-amplification gain updates in dB.
  Stream<double> get preamp => preampController.stream;

  /// Broadcast stream emitting ReplayGain normalization updates.
  Stream<ReplayGainConfig> get replayGain => replayGainController.stream;

  /// Broadcast stream emitting Bauer stereophonic-to-binaural crossfeed mode updates.
  Stream<CrossfeedMode> get crossfeed => crossfeedController.stream;

  /// Broadcast stream emitting whether stereo widening spatialization is enabled.
  Stream<bool> get spatializerEnabled => spatializerEnabledController.stream;

  /// Broadcast stream emitting stereo widening width factor updates.
  Stream<double> get spatializerWidth => spatializerWidthController.stream;

  /// Broadcast stream emitting studio algorithmic reverb configuration updates.
  Stream<Reverb> get reverb => reverbController.stream;

  /// Broadcast stream emitting whether the master brickwall limiter is active.
  Stream<bool> get limiterEnabled => limiterEnabledController.stream;

  /// Broadcast stream emitting the playlist queue of audio sources.
  Stream<List<AudioSource<T>>> get queue => queueController.stream;

  /// Broadcast stream emitting the index of the currently playing track in [queue].
  Stream<int> get currentIndex => currentIndexController.stream;

  /// Broadcast stream emitting the currently active [AudioSource], or `null` if empty.
  Stream<AudioSource<T>?> get currentItem => currentItemController.stream;

  /// Broadcast stream emitting playlist repeat and looping policy updates.
  Stream<LoopMode> get loopMode => loopModeController.stream;

  /// Broadcast stream emitting whether playlist shuffle mode is active.
  Stream<bool> get isShuffled => isShuffledController.stream;

  /// Broadcast stream emitting whether an automatic or manual crossfade transition is currently in progress.
  Stream<bool> get isCrossfading => isCrossfadingController.stream;

  /// Broadcast stream emitting crossfade duration and curve configuration updates.
  Stream<CrossfadeConfig> get crossfadeConfig => crossfadeConfigController.stream;

  /// Broadcast stream emitting whether live audio recording to a file sink is actively running.
  Stream<bool> get isRecording => isRecordingController.stream;

  /// Broadcast stream emitting the elapsed duration of active recording.
  Stream<Duration> get recordedDuration => recordedDurationController.stream;

  /// Broadcast stream emitting DJ cue headphone volume updates.
  Stream<double> get cueVolume => cueVolumeController.stream;

  /// Broadcast stream emitting DJ cue headphone routing source updates.
  Stream<CueSource> get cueSource => cueSourceController.stream;

  /// Broadcast stream emitting whether hardware microphone capture is active.
  Stream<bool> get isMicrophoneEnabled => isMicrophoneEnabledController.stream;

  /// Broadcast stream emitting microphone capture volume updates.
  Stream<double> get micVolume => micVolumeController.stream;

  /// Broadcast stream emitting whether voice auto-ducking is currently active.
  Stream<bool> get isDuckingActive => isDuckingActiveController.stream;

  /// Broadcast stream emitting whether direct microphone pass-through monitoring is active.
  Stream<bool> get isDirectMonitoringEnabled =>
      isDirectMonitoringEnabledController.stream;

  /// Broadcast stream emitting instantaneous microphone RMS levels in dBFS.
  Stream<double> get micRmsLevel => micRmsLevelController.stream;

  /// Broadcast stream emitting voice completion events for polyphonic effects.
  Stream<VoiceId> get voiceCompleted => voiceCompletedController.stream;

  /// Broadcast stream emitting the number of active polyphonic effect voices.
  Stream<int> get activeVoicesCount => activeVoicesCountController.stream;

  /// Broadcast stream emitting the total memory allocated for RAM sound effects in bytes.
  Stream<int> get allocatedRamBytes => allocatedRamBytesController.stream;

  /// Broadcast stream emitting the list of loaded effect IDs currently in RAM.
  Stream<List<String>> get loadedEffectIds => loadedEffectIdsController.stream;

  /// Broadcast stream emitting player exceptions and native errors.
  Stream<MiniaudioPlayerException> get errors => errorsController.stream;

  /// Broadcast stream emitting events when Infinite Mix approaches the queue end.
  Stream<NeedMoreTracksEvent> get needMoreTracks =>
      needMoreTracksController.stream;

  /// Closes all internal broadcast stream controllers.
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
