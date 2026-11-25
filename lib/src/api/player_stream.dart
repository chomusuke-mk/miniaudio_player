part of 'miniaudio_player.dart';

/// Reactive broadcast streams for observing playback, queue, effects, and DSP state changes.
///
/// In strict accordance with the stream-driven architecture, events originate from the native
/// Rust event pipeline and are dispatched to UI observers without artificial intermediate filtering.
class PlayerStream<T> {
  /// Broadcast controller for [position].
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  /// Broadcast controller for [duration].
  final StreamController<Duration?> _durationController =
      StreamController<Duration?>.broadcast();

  /// Broadcast controller for [audioInfo].
  final StreamController<AudioInfo?> _audioInfoController =
      StreamController<AudioInfo?>.broadcast();

  /// Broadcast controller for [isPlaying].
  final StreamController<bool> _playingController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [isBuffering].
  final StreamController<bool> _bufferingController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [playbackState].
  final StreamController<PlaybackState> _playbackStateController =
      StreamController<PlaybackState>.broadcast();

  /// Broadcast controller for [buffer].
  final StreamController<Buffer> _bufferController =
      StreamController<Buffer>.broadcast();

  /// Broadcast controller for [metadata].
  final StreamController<AudioMetadata?> _metadataController =
      StreamController<AudioMetadata?>.broadcast();

  /// Broadcast controller for [metadataEnabled].
  final StreamController<bool> _metadataEnabledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [volume].
  final StreamController<double> _volumeController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [rate].
  final StreamController<double> _rateController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [pitch].
  final StreamController<double> _pitchController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [balance].
  final StreamController<double> _balanceController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [mono].
  final StreamController<bool> _monoController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [bufferSize].
  final StreamController<int> _bufferSizeController =
      StreamController<int>.broadcast();

  /// Broadcast controller for [equalizer].
  final StreamController<Equalizer> _equalizerController =
      StreamController<Equalizer>.broadcast();

  /// Broadcast controller for [outputs].
  final StreamController<Set<AudioOutput>> _outputsController =
      StreamController<Set<AudioOutput>>.broadcast();

  /// Broadcast controller for [inputs].
  final StreamController<Set<AudioInput>> _inputsController =
      StreamController<Set<AudioInput>>.broadcast();

  /// Broadcast controller for [globalOutputDevices].
  final StreamController<List<AudioDevice>> _globalOutputDevicesController =
      StreamController<List<AudioDevice>>.broadcast();

  /// Broadcast controller for [globalInputDevices].
  final StreamController<List<AudioDevice>> _globalInputDevicesController =
      StreamController<List<AudioDevice>>.broadcast();

  /// Broadcast controller for [pauseOnDeviceChange].
  final StreamController<bool> _pauseOnDeviceChangeController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [skipSilence].
  final StreamController<bool> _skipSilenceController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [silenceConfig].
  final StreamController<SilenceSkipConfig> _silenceConfigController =
      StreamController<SilenceSkipConfig>.broadcast();

  /// Broadcast controller for [silenceSavedDuration].
  final StreamController<Duration> _silenceSavedDurationController =
      StreamController<Duration>.broadcast();

  /// Broadcast controller for [visualizer].
  final StreamController<VisualizerData> _visualizerController =
      StreamController<VisualizerData>.broadcast();

  /// Broadcast controller for [visualizerEnabled].
  final StreamController<bool> _visualizerEnabledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [visualizerSource].
  final StreamController<AudioOutputSource> _visualizerSourceController =
      StreamController<AudioOutputSource>.broadcast();

  /// Broadcast controller for [preamp].
  final StreamController<double> _preampController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [replayGain].
  final StreamController<ReplayGainConfig> _replayGainController =
      StreamController<ReplayGainConfig>.broadcast();

  /// Broadcast controller for [replayGainMode].
  final StreamController<ReplayGainMode> _replayGainModeController =
      StreamController<ReplayGainMode>.broadcast();

  /// Broadcast controller for [defaultReplayGain].
  final StreamController<double> _defaultReplayGainController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [crossfeed].
  final StreamController<Crossfeed> _crossfeedController =
      StreamController<Crossfeed>.broadcast();

  /// Broadcast controller for [spatializerEnabled].
  final StreamController<bool> _spatializerEnabledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [spatializerWidth].
  final StreamController<double> _spatializerWidthController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [reverb].
  final StreamController<Reverb> _reverbController =
      StreamController<Reverb>.broadcast();

  /// Broadcast controller for [limiterEnabled].
  final StreamController<bool> _limiterEnabledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [queue].
  final StreamController<List<AudioSource<T>>> _queueController =
      StreamController<List<AudioSource<T>>>.broadcast();

  /// Broadcast controller for [currentIndex].
  final StreamController<int?> _currentIndexController =
      StreamController<int?>.broadcast();

  /// Broadcast controller for [currentItem].
  final StreamController<AudioSource<T>?> _currentItemController =
      StreamController<AudioSource<T>?>.broadcast();

  /// Broadcast controller for [loopMode].
  final StreamController<LoopMode> _loopModeController =
      StreamController<LoopMode>.broadcast();

  /// Broadcast controller for [isShuffled].
  final StreamController<bool> _isShuffledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [infiniteMix].
  final StreamController<InfiniteMixConfig> _infiniteMixController =
      StreamController<InfiniteMixConfig>.broadcast();

  /// Broadcast controller for [infiniteMixEnabled].
  final StreamController<bool> _infiniteMixEnabledController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [isCrossfading].
  final StreamController<bool> _isCrossfadingController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [crossfadeConfig].
  final StreamController<CrossfadeConfig> _crossfadeConfigController =
      StreamController<CrossfadeConfig>.broadcast();

  /// Broadcast controller for [isRecording].
  final StreamController<bool> _isRecordingController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [recordingSource].
  final StreamController<AudioOutputSource?> _recordingSourceController =
      StreamController<AudioOutputSource?>.broadcast();

  /// Broadcast controller for [recordedDuration].
  final StreamController<Duration> _recordedDurationController =
      StreamController<Duration>.broadcast();

  /// Broadcast controller for [isDuckingActive].
  final StreamController<bool> _isDuckingActiveController =
      StreamController<bool>.broadcast();

  /// Broadcast controller for [micRmsLevel].
  final StreamController<double> _micRmsLevelController =
      StreamController<double>.broadcast();

  /// Broadcast controller for [voiceCompleted].
  final StreamController<int> _voiceCompletedController =
      StreamController<int>.broadcast();

  /// Broadcast controller for [activeVoicesCount].
  final StreamController<int> _activeVoicesCountController =
      StreamController<int>.broadcast();

  /// Broadcast controller for [allocatedRamBytes].
  final StreamController<int> _allocatedRamBytesController =
      StreamController<int>.broadcast();

  /// Broadcast controller for [loadedEffectIds].
  final StreamController<List<String>> _loadedEffectIdsController =
      StreamController<List<String>>.broadcast();

  /// Broadcast controller for [errors].
  final StreamController<MiniaudioPlayerException> _errorsController =
      StreamController<MiniaudioPlayerException>.broadcast();

  /// Optional owning player used to seed immediate-replay streams.
  final MiniaudioPlayer<T>? _player;

  /// Creates a [PlayerStream] container with broadcast stream controllers for [_player].
  PlayerStream([this._player]);

  /// Broadcast stream emitting the playback position within the active track.
  Stream<Duration> get position => _positionController.stream;

  /// Reactive broadcast stream emitting the total timeline duration of the active audio track,
  /// or `null` if unknown (e.g. livestream).
  Stream<Duration?> get duration => _durationController.stream;

  /// Broadcast stream emitting whether audio frames are actively rendering.
  Stream<bool> get isPlaying => _playingController.stream;

  /// Broadcast stream emitting whether playback is stalled waiting for data.
  Stream<bool> get isBuffering => _bufferingController.stream;

  /// Broadcast stream emitting high-level playback state changes.
  Stream<PlaybackState> get playbackState => _playbackStateController.stream;

  /// Broadcast stream emitting audio prefetch buffer metrics.
  Stream<Buffer> get buffer => _bufferController.stream;

  /// Reactive broadcast stream emitting updates whenever metadata dispatch is enabled or disabled.
  Stream<bool> get metadataEnabled => _metadataEnabledController.stream;

  /// Reactive broadcast stream emitting encapsulated [AudioMetadata] when [metadataEnabled] is `true`.
  Stream<AudioMetadata?> get metadata => _metadataController.stream;

  /// Reactive broadcast stream emitting technical audio format characteristics
  /// (duration, sample rate, channels, nominal bitrate, and format).
  Stream<AudioInfo?> get audioInfo => _audioInfoController.stream;

  /// Broadcast stream emitting master volume updates (`>= 0.0`).
  Stream<double> get volume => _volumeController.stream;

  /// Broadcast stream emitting playback rate multiplier updates (`> 0.0`).
  Stream<double> get rate => _rateController.stream;

  /// Broadcast stream emitting pitch shift multiplier updates (`> 0.0`).
  Stream<double> get pitch => _pitchController.stream;

  /// Broadcast stream emitting stereo balance panning updates (`-1.0` to `1.0`).
  Stream<double> get balance => _balanceController.stream;

  /// Broadcast stream emitting mono downmix state updates.
  Stream<bool> get mono => _monoController.stream;

  /// Broadcast stream emitting audio buffer frame size updates.
  Stream<int> get bufferSize => _bufferSizeController.stream;

  /// Broadcast stream emitting 10-band equalizer configuration updates.
  Stream<Equalizer> get equalizer => _equalizerController.stream;

  /// Reactive broadcast stream emitting this player's active output destinations.
  ///
  /// When both `'AUTO'` and a matching physical device ID are active simultaneously,
  /// the native Rust audio engine deduplicates the hardware endpoint (prioritizing `'AUTO'`),
  /// while this stream continues to emit the full declared set configured by the user.
  Stream<Set<AudioOutput>> get outputs => _outputsController.stream;

  /// Reactive broadcast stream emitting this player's active input sources.
  ///
  /// When both `'AUTO'` and a matching physical capture device ID are active simultaneously,
  /// the native Rust audio engine deduplicates the hardware endpoint (prioritizing `'AUTO'`),
  /// while this stream continues to emit the full declared set configured by the user.
  Stream<Set<AudioInput>> get inputs => _inputsController.stream;

  /// Reactive broadcast stream emitting updates to the global system output devices list.
  ///
  /// Emits the current snapshot immediately on subscription, followed by all live hardware changes.
  Stream<List<AudioDevice>> get globalOutputDevices =>
      _createImmediateReplayStream(
        _globalOutputDevicesController.stream,
        () => _player?.state.globalOutputDevices ?? const [],
      );

  /// Reactive broadcast stream emitting updates to the global system input devices list.
  ///
  /// Emits the current snapshot immediately on subscription, followed by all live hardware changes.
  Stream<List<AudioDevice>> get globalInputDevices =>
      _createImmediateReplayStream(
        _globalInputDevicesController.stream,
        () => _player?.state.globalInputDevices ?? const [],
      );

  /// Returns a broadcast stream that emits the snapshot from [currentGetter]
  /// immediately on subscription before forwarding events from [source].
  Stream<R> _createImmediateReplayStream<R>(
    Stream<R> source,
    R Function() currentGetter,
  ) {
    return Stream<R>.multi((controller) {
      controller.add(currentGetter());
      final sub = source.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    }, isBroadcast: true);
  }

  /// Broadcast stream emitting whether playback automatically pauses on output device disconnect.
  Stream<bool> get pauseOnDeviceChange => _pauseOnDeviceChangeController.stream;

  /// Broadcast stream emitting whether silence skipping is enabled.
  Stream<bool> get skipSilence => _skipSilenceController.stream;

  /// Broadcast stream emitting silence skipping configuration updates.
  Stream<SilenceSkipConfig> get silenceConfig =>
      _silenceConfigController.stream;

  /// Broadcast stream emitting cumulative playback time saved by skipping silence.
  Stream<Duration> get silenceSavedDuration =>
      _silenceSavedDurationController.stream;

  /// Reactive broadcast stream emitting real-time 10-band FFT spectrum visualizer metrics.
  ///
  /// This stream is always open for listeners, but events are only computed and emitted
  /// when [visualizerEnabled] is set to `true` via [PlayerAction.setVisualizerEnabled].
  Stream<VisualizerData> get visualizer => _visualizerController.stream;

  /// Reactive broadcast stream emitting updates whenever the visualizer DSP calculation is enabled or disabled.
  Stream<bool> get visualizerEnabled => _visualizerEnabledController.stream;

  /// Reactive broadcast stream emitting updates whenever the visualizer audio source changes.
  Stream<AudioOutputSource> get visualizerSource =>
      _visualizerSourceController.stream;

  /// Broadcast stream emitting master pre-amplification gain updates in dB.
  Stream<double> get preamp => _preampController.stream;

  /// Broadcast stream emitting ReplayGain normalization updates.
  Stream<ReplayGainConfig> get replayGain => _replayGainController.stream;

  /// Broadcast stream emitting active ReplayGain operating mode.
  Stream<ReplayGainMode> get replayGainMode => _replayGainModeController.stream;

  /// Broadcast stream emitting default fallback ReplayGain in dB.
  Stream<double> get defaultReplayGain => _defaultReplayGainController.stream;

  /// Broadcast stream emitting Bauer stereophonic-to-binaural crossfeed configuration updates.
  Stream<Crossfeed> get crossfeed => _crossfeedController.stream;

  /// Broadcast stream emitting whether stereo widening spatialization is enabled.
  Stream<bool> get spatializerEnabled => _spatializerEnabledController.stream;

  /// Broadcast stream emitting stereo widening width factor updates.
  Stream<double> get spatializerWidth => _spatializerWidthController.stream;

  /// Broadcast stream emitting studio algorithmic reverb configuration updates.
  Stream<Reverb> get reverb => _reverbController.stream;

  /// Broadcast stream emitting whether the master brickwall limiter is active.
  Stream<bool> get limiterEnabled => _limiterEnabledController.stream;

  /// Broadcast stream emitting the playlist queue of audio sources.
  Stream<List<AudioSource<T>>> get queue => _queueController.stream;

  /// Broadcast stream emitting the index of the currently playing track in [queue],
  /// or `null` if no track is active.
  Stream<int?> get currentIndex => _currentIndexController.stream;

  /// Broadcast stream emitting the currently active [AudioSource], or `null` if empty.
  Stream<AudioSource<T>?> get currentItem => _currentItemController.stream;

  /// Broadcast stream emitting playlist repeat and looping policy updates.
  Stream<LoopMode> get loopMode => _loopModeController.stream;

  /// Broadcast stream emitting whether playlist shuffle mode is active.
  Stream<bool> get isShuffled => _isShuffledController.stream;

  /// Broadcast stream emitting Infinite Mix dynamic queue replenishment configuration updates.
  Stream<InfiniteMixConfig> get infiniteMix => _infiniteMixController.stream;

  /// Broadcast stream emitting whether Infinite Mix dynamic queue replenishment is active.
  Stream<bool> get infiniteMixEnabled => _infiniteMixEnabledController.stream;

  /// Broadcast stream emitting whether an automatic or manual crossfade transition is currently in progress.
  Stream<bool> get isCrossfading => _isCrossfadingController.stream;

  /// Broadcast stream emitting crossfade duration and curve configuration updates.
  Stream<CrossfadeConfig> get crossfadeConfig =>
      _crossfadeConfigController.stream;

  /// Broadcast stream emitting whether live audio recording to a file sink is actively running.
  Stream<bool> get isRecording => _isRecordingController.stream;

  /// Broadcast stream emitting the audio signal source being captured by active recording.
  Stream<AudioOutputSource?> get recordingSource =>
      _recordingSourceController.stream;

  /// Broadcast stream emitting the elapsed duration of active recording.
  Stream<Duration> get recordedDuration => _recordedDurationController.stream;

  /// Broadcast stream emitting whether voice auto-ducking is currently active.
  Stream<bool> get isDuckingActive => _isDuckingActiveController.stream;

  /// Broadcast stream emitting instantaneous microphone RMS levels in dBFS.
  Stream<double> get micRmsLevel => _micRmsLevelController.stream;

  /// Broadcast stream emitting voice completion events for polyphonic effects.
  Stream<int> get voiceCompleted => _voiceCompletedController.stream;

  /// Broadcast stream emitting the number of active polyphonic effect voices.
  Stream<int> get activeVoicesCount => _activeVoicesCountController.stream;

  /// Broadcast stream emitting the total memory allocated for RAM sound effects in bytes.
  Stream<int> get allocatedRamBytes => _allocatedRamBytesController.stream;

  /// Broadcast stream emitting the list of loaded effect IDs currently in RAM.
  Stream<List<String>> get loadedEffectIds => _loadedEffectIdsController.stream;

  /// Broadcast stream emitting player exceptions and native errors.
  Stream<MiniaudioPlayerException> get errors => _errorsController.stream;

  /// Closes all internal broadcast stream controllers.
  Future<void> dispose() async {
    MapLogger.debug('[PlayerStream] Disposing broadcast stream controllers.');
    await Future.wait([
      _positionController.close(),
      _durationController.close(),
      _playingController.close(),
      _bufferingController.close(),
      _playbackStateController.close(),
      _bufferController.close(),
      _activeVoicesCountController.close(),
      _allocatedRamBytesController.close(),
      _loadedEffectIdsController.close(),
      _audioInfoController.close(),
      _metadataController.close(),
      _metadataEnabledController.close(),
      _volumeController.close(),
      _rateController.close(),
      _pitchController.close(),
      _balanceController.close(),
      _monoController.close(),
      _bufferSizeController.close(),
      _equalizerController.close(),
      _outputsController.close(),
      _inputsController.close(),
      _globalOutputDevicesController.close(),
      _globalInputDevicesController.close(),
      _pauseOnDeviceChangeController.close(),
      _skipSilenceController.close(),
      _silenceConfigController.close(),
      _silenceSavedDurationController.close(),
      _visualizerController.close(),
      _visualizerEnabledController.close(),
      _visualizerSourceController.close(),
      _preampController.close(),
      _replayGainController.close(),
      _replayGainModeController.close(),
      _defaultReplayGainController.close(),
      _crossfeedController.close(),
      _spatializerEnabledController.close(),
      _spatializerWidthController.close(),
      _reverbController.close(),
      _limiterEnabledController.close(),
      _queueController.close(),
      _currentIndexController.close(),
      _currentItemController.close(),
      _loopModeController.close(),
      _isShuffledController.close(),
      _infiniteMixController.close(),
      _infiniteMixEnabledController.close(),
      _isCrossfadingController.close(),
      _crossfadeConfigController.close(),
      _isRecordingController.close(),
      _recordingSourceController.close(),
      _recordedDurationController.close(),
      _isDuckingActiveController.close(),
      _micRmsLevelController.close(),
      _voiceCompletedController.close(),
      _errorsController.close(),
    ]);
  }
}
