part of 'miniaudio_engine.dart';

/// Action interface executing asynchronous playback, queue navigation,
/// crossfade configuration, and DSP controls on [MiniaudioEngine].
///
/// Mirrors the full control surface of [PlayerAction] while adding first-class
/// queue management, shuffle/loop policies, automatic/manual crossfading,
/// per-track ReplayGain normalization, and Infinite Mix controls.
class EngineAction<T> {
  final MiniaudioEngine<T> _engine;

  EngineAction._(this._engine);

  // --------------------------------------------------------------------------
  // Single-Source & Queue Opening
  // --------------------------------------------------------------------------

  /// Replaces the queue with [items] and prepares the initial entry at [startIndex]
  /// without starting playback. Call [play] to start playback.
  Future<void> open(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) =>
      _engine._openQueue(
        items,
        startIndex: startIndex,
        shuffle: shuffle,
      );

  /// Alias for [open]. Replaces the queue with [items] and prepares the entry at [startIndex].
  Future<void> openQueue(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) =>
      open(items, startIndex: startIndex, shuffle: shuffle);

  // --------------------------------------------------------------------------
  // Transport Controls
  // --------------------------------------------------------------------------

  /// Starts or resumes playback of the active deck (or active crossfade).
  Future<void> play() => _engine._play();

  /// Pauses playback of the active deck (and freezes any active crossfade ramp).
  Future<void> pause() => _engine._pause();

  /// Toggles between [play] and [pause].
  Future<void> togglePlayPause() => _engine._togglePlayPause();

  /// Stops playback on both decks and resets position to the beginning.
  Future<void> stop() => _engine._stop();

  /// Seeks to [position] on the active track.
  Future<void> seek(Duration position) => _engine._seek(position);

  // --------------------------------------------------------------------------
  // Queue Navigation & Mutations
  // --------------------------------------------------------------------------

  /// Advances to the next item in the queue.
  Future<void> next() => _engine._next();

  /// Steps to the previous item in the queue, or restarts the current track at
  /// `0:00` if playback position exceeds `3 seconds`.
  Future<void> previous() => _engine._previous();

  /// Jumps directly to [index] in the active queue, preserving current playback state.
  Future<void> skipToIndex(int index) => _engine._skipToIndex(index);

  /// Inserts [item] immediately after the currently playing item.
  Future<void> insertNext(EngineItem<T> item) => _engine._insertNext(item);

  /// Appends [items] to the end of the active queue.
  Future<void> append(List<EngineItem<T>> items) => _engine._append(items);

  /// Removes the item at [index] from the queue.
  Future<void> removeAt(int index) => _engine._removeAt(index);

  /// Moves the queue item at [from] to [to] without interrupting playback.
  Future<void> reorder(int from, int to) => _engine._reorder(from, to);

  /// Clears the queue.
  Future<void> clearQueue({bool keepCurrent = true}) =>
      _engine._clearQueue(keepCurrent: keepCurrent);

  // --------------------------------------------------------------------------
  // Shuffle, Loop, Crossfade, ReplayGain & Infinite Mix Policies
  // --------------------------------------------------------------------------

  /// Explicitly enables or disables Fisher-Yates shuffle mode.
  Future<void> setShuffle(bool enabled) => _engine._setShuffle(enabled);

  /// Toggles Fisher-Yates shuffle mode on or off.
  Future<bool> toggleShuffle() => _engine._toggleShuffle();

  /// Sets the queue repeat policy ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  Future<void> setLoopMode(LoopMode mode) => _engine._setLoopMode(mode);

  /// Cycles the queue repeat policy in order: `off -> all -> one -> off`.
  Future<LoopMode> cycleLoopMode() => _engine._cycleLoopMode();

  /// Updates the complete [CrossfadeConfig] (automatic duration, manual
  /// duration, and interpolation curve).
  Future<void> setCrossfadeConfig(CrossfadeConfig config) =>
      _engine._setCrossfadeConfig(config);

  /// Updates the automatic end-of-track crossfade [duration] (`0s..12s`).
  Future<void> setCrossfadeDuration(Duration duration) =>
      _engine._setCrossfadeConfig(
        _engine.state.crossfadeConfig.copyWith(duration: duration),
      );

  /// Updates the manual skip crossfade [manualDuration] (`0s..12s`).
  Future<void> setManualCrossfadeDuration(Duration manualDuration) =>
      _engine._setCrossfadeConfig(
        _engine.state.crossfadeConfig.copyWith(manualDuration: manualDuration),
      );

  /// Updates the crossfade gain interpolation [curve] ([CrossfadeCurve.equalPower]
  /// or [CrossfadeCurve.linear]).
  Future<void> setCrossfadeCurve(CrossfadeCurve curve) =>
      _engine._setCrossfadeConfig(
        _engine.state.crossfadeConfig.copyWith(curve: curve),
      );

  /// Enables or disables automatic per-item ReplayGain loudness normalization.
  Future<void> setVolumeNormalization(bool enabled) =>
      _engine._setVolumeNormalization(enabled);

  /// Sets the default fallback ReplayGain in decibels applied to queue items that
  /// do not specify their own [EngineItem.replayGainDb].
  Future<void> setDefaultReplayGain(double gainDb) =>
      _engine._setDefaultReplayGain(gainDb);

  /// Forces a uniform global ReplayGain across all queue items in the engine,
  /// overriding individual track metadata.
  Future<void> setForcedReplayGain(double? gainDb) =>
      _engine._setForcedReplayGain(gainDb);

  /// Enables or disables proactive Infinite Mix lookahead prefetching.
  Future<void> setInfiniteMix(bool enabled) => _engine._setInfiniteMix(enabled);

  // --------------------------------------------------------------------------
  // Volume, Speed, Pitch, Device & Studio DSP Suite
  // --------------------------------------------------------------------------

  /// Sets the master audio volume level (`0.0` to `2.0`, default `1.0`).
  Future<void> setVolume(double volume) => _engine._setVolume(volume);

  /// Sets the playback speed multiplier (`0.1` to `4.0`, default `1.0`).
  Future<void> setRate(double rate) => _engine._setRate(rate);

  /// Sets the audio pitch multiplier (`0.5` to `2.0`, default `1.0`).
  Future<void> setPitch(double pitch) => _engine._setPitch(pitch);

  /// Sets the internal native buffer size in frames (`0` = native default) on
  /// both decks.
  Future<void> setBufferSize(int bufferSize) =>
      _engine._setBufferSize(bufferSize);

  /// Applies a 10-band [Equalizer] configuration across both decks.
  Future<void> setEqualizer(Equalizer equalizer) =>
      _engine._setEqualizer(equalizer);

  /// Updates a single equalizer band at [index] (`0..9`) with [gainDb] (`-24.0..+24.0`).
  Future<void> setEqualizerBand(int index, double gainDb) {
    final updated = _engine.state.equalizer.withBand(index, gainDb);
    return _engine._setEqualizer(updated);
  }

  /// Resets all 10 equalizer bands to `0.0 dB` ([Equalizer.flat]).
  Future<void> resetEqualizer() => _engine._setEqualizer(Equalizer.flat);

  /// Sets the active audio output [device] across both decks.
  Future<void> setDevice(AudioDevice device) => _engine._setDevice(device);

  /// Sets whether playback should automatically pause when the active audio output endpoint changes across both decks.
  void setPauseOnDeviceChange(bool enabled) =>
      _engine._setPauseOnDeviceChange(enabled);

  /// Enables or disables silence skipping across both decks.
  Future<void> setSkipSilence(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) =>
      _engine._setSkipSilence(
        enabled,
        mode: mode,
        thresholdDb: thresholdDb,
        minSilenceDuration: minSilenceDuration,
        padding: padding,
      );

  /// Applies a complete [SilenceSkipConfig] across both decks.
  Future<void> setSilenceConfig(SilenceSkipConfig config) =>
      _engine._setSilenceConfig(config);

  /// Forces real-time visualizer DSP extraction enabled or disabled.
  Future<void> setVisualizerEnabled(bool enabled) =>
      _engine._setVisualizerOverride(enabled);

  /// Clears any manual visualizer override, reverting to reactive on-demand
  /// activation based on [EngineStream.visualizer] listeners.
  Future<void> clearVisualizerOverride() =>
      _engine._setVisualizerOverride(null);

  /// Sets ReplayGain normalization for the engine.
  Future<void> setReplayGain({
    required double gainDb,
    double? peak,
    bool preventClipping = true,
    bool force = false,
  }) =>
      _engine._setReplayGain(
        gainDb: gainDb,
        peak: peak,
        preventClipping: preventClipping,
        force: force,
      );

  /// Clears forced ReplayGain normalization and active deck normalization back to unity gain (`0.0 dB`).
  Future<void> clearReplayGain() => _engine._clearReplayGain();

  /// Sets standalone manual preamp gain in decibels (`-12.0` to `+12.0` dB)
  /// across both decks.
  Future<void> setPreamp(double preampDb) => _engine._setPreamp(preampDb);

  /// Sets stereo channel balance (`-1.0` full left, `0.0` center, `+1.0` full right)
  /// across both decks.
  Future<void> setBalance(double pan) => _engine._setBalance(pan);

  /// Enables or disables mono downmixing across both decks.
  Future<void> setMono(bool enabled) => _engine._setMono(enabled);

  /// Configures headphone binaural crossfeed ([CrossfeedMode]) across both decks.
  Future<void> setCrossfeed(CrossfeedMode mode) => _engine._setCrossfeed(mode);

  /// Configures the stereo widener / spatializer across both decks.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.3,
  }) =>
      _engine._setSpatializer(enabled: enabled, width: width);

  /// Enables or disables 3D spatial audio and Doppler shift processing.
  Future<void> setSpatialEnabled(bool enabled) async {
    _engine.spatial.setEnabled(enabled);
  }

  /// Sets the 3D spatial listener state.
  Future<void> setSpatialListener({
    Vector3? position,
    Vector3? velocity,
    Vector3? forward,
    Vector3? up,
  }) async {
    _engine.spatial.setListener(
      position: position,
      velocity: velocity,
      forward: forward,
      up: up,
    );
  }

  /// Sets the 3D spatial emitter state.
  Future<void> setSpatialEmitter({
    Vector3? position,
    Vector3? velocity,
    Vector3? direction,
    double? minDistance,
    double? maxDistance,
    double? rolloff,
    double? dopplerFactor,
    double? innerAngleRad,
    double? outerAngleRad,
    double? outerGain,
    DistanceModel? distanceModel,
  }) async {
    _engine.spatial.setEmitter(
      position: position,
      velocity: velocity,
      direction: direction,
      minDistance: minDistance,
      maxDistance: maxDistance,
      rolloff: rolloff,
      dopplerFactor: dopplerFactor,
      innerAngleRad: innerAngleRad,
      outerAngleRad: outerAngleRad,
      outerGain: outerGain,
      distanceModel: distanceModel,
    );
  }

  /// Sets the Doppler effect exaggeration/reduction factor (default 1.0, 0.0 disables Doppler).
  Future<void> setSpatialDopplerFactor(double factor) async {
    _engine.spatial.setDopplerFactor(factor);
  }

  /// Sets the medium speed of sound in m/s (default 343.3 m/s).
  Future<void> setSpatialSpeedOfSound(double speed) async {
    _engine.spatial.setSpeedOfSound(speed);
  }

  /// Enables or disables the True-Peak soft-knee output limiter across both decks.
  Future<void> setLimiter(bool enabled) => _engine._setLimiter(enabled);

  /// Configures studio-grade algorithmic reverberation ([Reverb]) across both decks.
  Future<void> setReverb(Reverb config) => _engine._setReverb(config);

  // --------------------------------------------------------------------------
  // Decoupled Sinks, Recording & Cue Pre-listening
  // --------------------------------------------------------------------------

  /// Starts live background recording of the mixed audio output to a RIFF WAV file at [path].
  Future<void> startRecording(
    String path, {
    WavFormat format = WavFormat.pcm16,
  }) =>
      _engine._startRecording(path, format: format);

  /// Stops the active recording session, finalizes RIFF WAV chunk sizes, and flushes to disk.
  Future<int> stopRecording() => _engine._stopRecording();

  /// Whether a live recording session is currently active.
  bool isRecording() => _engine._checkIsRecording();

  /// Renders a fast offline mix (bounce) of the current queue directly to a WAV file at [path].
  Future<int> offlineBounce(
    String path, {
    WavFormat format = WavFormat.pcm16,
    required Duration duration,
  }) =>
      _engine._offlineBounce(path, format: format, duration: duration);

  /// Enables real-time microphone / line-in capture into the mix with optional auto-ducking sidechain.
  Future<void> enableMicrophone({
    String? captureDeviceId,
    bool autoDucking = true,
    double duckingDb = -14.0,
    double thresholdDb = -30.0,
  }) =>
      _engine._enableMicrophone(
        captureDeviceId: captureDeviceId,
        autoDucking: autoDucking,
        duckingDb: duckingDb,
        thresholdDb: thresholdDb,
      );

  /// Disables microphone capture and tears down the hardware capture device node.
  Future<void> disableMicrophone() => _engine._disableMicrophone();

  /// Sets the input volume multiplier for captured microphone audio (0.0 to 2.0).
  Future<void> setMicVolume(double volume) => _engine._setMicVolume(volume);

  /// Configures a secondary audio output device for DJ cue pre-listening or voice chat.
  Future<void> configureCueOutput({
    String? deviceId,
    double volume = 1.0,
    CueMode mode = CueMode.deckA,
  }) =>
      _engine._configureCueOutput(
        deviceId: deviceId,
        volume: volume,
        mode: mode,
      );

  /// Sets the DJ cue headphone pre-listening volume level (0.0 to 2.0).
  Future<void> setCueVolume(double volume) => _engine._setCueVolume(volume);

  /// Sets the DJ cue pre-listening source routing mode ([CueMode.deckA], [CueMode.deckB], [CueMode.master]).
  Future<void> setCueMode(CueMode mode) => _engine._setCueMode(mode);

  /// Disables the secondary DJ cue output and tears down its device.
  Future<void> disableCueOutput() => _engine._disableCueOutput();

  /// Configures master playback, cue pre-listening, and optional live recording in a single unified call.
  Future<void> configureOutputs({
    AudioDevice? masterDevice,
    AudioDevice? cueDevice,
    String? recordPath,
    WavFormat format = WavFormat.pcm16,
  }) =>
      _engine._configureOutputs(
        masterDevice: masterDevice,
        cueDevice: cueDevice,
        recordPath: recordPath,
        format: format,
      );
}
