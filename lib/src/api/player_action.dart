part of 'miniaudio_player.dart';

/// Deterministic numeric validator for audio and DSP parameters.
abstract final class _AudioParamValidator {
  static void requireFinite(double value, String name, String label) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError.value(value, name, '$label must be finite');
    }
  }

  static void requireFiniteNonNegative(
      double value, String name, String label) {
    if (value.isNaN || value.isInfinite || value < 0.0) {
      throw ArgumentError.value(
        value,
        name,
        '$label must be finite and non-negative',
      );
    }
  }

  static void requireFinitePositive(double value, String name, String label) {
    if (value.isNaN || value.isInfinite || value <= 0.0) {
      throw ArgumentError.value(
        value,
        name,
        '$label must be finite and positive',
      );
    }
  }
}

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final MiniaudioPlayer _player;

  int _openGeneration = 0;
  int _seekGeneration = 0;
  Completer<void>? _openingCompleter;
  bool _playRequested = false;
  Future<void>? _pendingSeekFuture;
  DartByteProviderBridge? _customBridge;
  AudioSource? _currentSource;
  bool _streamNeedsReopenOnPlay = false;

  PlayerAction._(this._player);

  /// Awaits completion of the currently in-flight audio source opening operation.
  Future<void> waitUntilOpen() => _openingCompleter?.future ?? Future.value();

  void _dispose() {
    _openGeneration++;
    _playRequested = false;
    _pendingSeekFuture = null;
    _disposeCustomBridge();
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openingCompleter!.complete();
    }
  }

  void _disposeCustomBridge() {
    final bridge = _customBridge;
    _customBridge = null;
    bridge?.dispose();
  }

  /// Guard wrapper executing an open task within the Opening Gate.
  Future<void> _openGuarded(
    Future<void> Function(int generation) openTask,
  ) async {
    _player._ensureNotDisposed();

    final gen = ++_openGeneration;
    _playRequested = false;
    _pendingSeekFuture = null;

    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openingCompleter!.complete();
    }
    final completer = Completer<void>();
    completer.future.ignore();
    _openingCompleter = completer;

    final prevBridge = _customBridge;
    _customBridge = null;

    _player._resetMetadata();
    _player._notifyOpening();

    prevBridge?.dispose();
    if (_openGeneration != gen || _player._isDisposed) return;

    try {
      await openTask(gen);
      if (_openGeneration != gen) return;

      _player._notifyOpenCompleted();
      if (!completer.isCompleted) {
        completer.complete();
      }
    } catch (error, stackTrace) {
      if (_openGeneration != gen) return;

      MapLogger.error('open() failed for source $_currentSource: $error');
      _disposeCustomBridge();
      _player._notifyOpenFailed();

      if (!completer.isCompleted) {
        completer.future.ignore();
        completer.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// Prepares an audio source for playback.
  Future<void> open(AudioSource source) async {
    _player._ensureNotDisposed();
    MapLogger.info('open() requested for source: $source');
    _currentSource = source;
    _streamNeedsReopenOnPlay = false;
    _disposeCustomBridge();

    return _openGuarded((_) async {
      switch (source) {
        case UriAudioSource s:
          await _openUriSource(s);
        case MemoryAudioSource s:
          await _openMemorySource(s);
        case CustomAudioSource s:
          await _openCustomSource(s);
      }
    });
  }

  Future<void> _openUriSource(UriAudioSource source) async {
    final str = source.sourceString;
    if (str.isEmpty) {
      throw const MiniaudioPlayerException(
        'Cannot open empty source path or URL',
      );
    }
    MapLogger.debug('_openUriSource -> uri: $str');
    final assetBytes = await _tryLoadFlutterAsset(str);
    if (assetBytes != null) {
      MapLogger.debug('_openUriSource resolved Flutter asset -> ${assetBytes.length} bytes');
      await _player._backend.openMemory(assetBytes);
      return;
    }
    await _player._backend.openSource(str, headers: source.headers);
  }

  Future<Uint8List?> _tryLoadFlutterAsset(String uriString) async {
    if (!uriString.startsWith('asset://') && !uriString.startsWith('asset:')) {
      return null;
    }
    final loader = MiniaudioPlayerGlobalConfig.assetLoader;
    if (loader == null) return null;

    final key = uriString.startsWith('asset://')
        ? uriString.substring('asset://'.length)
        : uriString.substring('asset:'.length);
    try {
      return await loader(key);
    } catch (_) {
      return null;
    }
  }

  Future<void> _openMemorySource(MemoryAudioSource source) async {
    if (source.bytes.isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty byte buffer');
    }
    MapLogger.debug('_openMemorySource -> ${source.bytes.length} bytes');
    await _player._backend.openMemory(source.bytes);
  }

  Future<void> _openCustomSource(CustomAudioSource source) async {
    MapLogger.debug('_openCustomSource -> streamId: ${source.provider.streamId}');
    final bridge = DartByteProviderBridge(_player._backend, source.provider);
    _customBridge = bridge;
    await bridge.start();
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    _player._ensureNotDisposed();
    MapLogger.info('play() requested (state: ${_player.state.playbackState})');
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _playRequested = true;
      final gen = _openGeneration;
      try {
        await _openingCompleter!.future;
      } catch (_) {
        return;
      }
      if (_openGeneration != gen || !_playRequested) return;
    }
    if (_pendingSeekFuture != null) {
      try {
        await _pendingSeekFuture;
      } catch (_) {}
    }
    return _executePlay();
  }

  Future<void> _executePlay() async {
    if (_streamNeedsReopenOnPlay &&
        _player.state.trackMetadata?.isLiveStream == true &&
        _currentSource != null) {
      _streamNeedsReopenOnPlay = false;
      await open(_currentSource!);
    }
    if (_player.state.completed ||
        (_player.state.duration > Duration.zero &&
            _player.state.position >= _player.state.duration)) {
      final seekFut = _executeSeek(Duration.zero);
      _pendingSeekFuture = seekFut;
      await seekFut;
      if (_pendingSeekFuture == seekFut) {
        _pendingSeekFuture = null;
      }
    }
    await _player._backend.play();
  }

  /// Pauses audio playback at the current position.
  Future<void> pause() async {
    _player._ensureNotDisposed();
    MapLogger.info('pause() requested (state: ${_player.state.playbackState})');
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _playRequested = false;
      return;
    }
    await _player._backend.pause();
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    _player._ensureNotDisposed();
    MapLogger.info('stop() requested (state: ${_player.state.playbackState})');
    if (_player.state.trackMetadata?.isLiveStream == true) {
      _streamNeedsReopenOnPlay = true;
    }
    _pendingSeekFuture = null;
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openGeneration++;
      _playRequested = false;
      _disposeCustomBridge();
      try {
        await _player._backend.stop();
      } catch (_) {}
      if (!_openingCompleter!.isCompleted) {
        _openingCompleter!.complete();
      }
      _player._notifyStopped();
      return;
    }
    await _player._backend.stop();
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) {
    _player._ensureNotDisposed();
    final targetPosition = position < Duration.zero ? Duration.zero : position;
    MapLogger.debug('seek() requested -> ${targetPosition.inMilliseconds}ms');
    final thisSeekGen = ++_seekGeneration;

    Future<void> doSeek() async {
      if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
        final gen = _openGeneration;
        try {
          await _openingCompleter!.future;
        } catch (_) {
          return;
        }
        if (_openGeneration != gen || _seekGeneration != thisSeekGen) return;
      }
      if (_seekGeneration != thisSeekGen) return;
      return _executeSeek(targetPosition);
    }

    final future = doSeek();
    _pendingSeekFuture = future;
    return future;
  }

  Future<void> _executeSeek(Duration position) async {
    await _player._backend.seek(position);
  }

  /// Sets master volume as a linear amplitude scale (`0.0` to `2.0`).
  Future<void> setVolume(double volume) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFiniteNonNegative(volume, 'volume', 'Volume');
    final clamped = volume.clamp(0.0, 2.0);
    MapLogger.debug('setVolume() -> $clamped');
    _player._volume.emitIfChanged(clamped);
    _player._backend.setVolume(clamped);
  }

  /// Sets playback speed/rate (`0.1` to `4.0`, where `1.0` is normal).
  Future<void> setRate(double rate) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinitePositive(rate, 'rate', 'Rate');
    final clamped = rate.clamp(0.1, 4.0);
    MapLogger.debug('setRate() -> $clamped');
    _player._rate.emitIfChanged(clamped);
    _player._backend.setRate(clamped);
  }

  /// Sets playback pitch scale (`0.5` to `2.0`, where `1.0` is original pitch).
  Future<void> setPitch(double pitch) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinitePositive(pitch, 'pitch', 'Pitch');
    final clamped = pitch.clamp(0.5, 2.0);
    MapLogger.debug('setPitch() -> $clamped');
    _player._pitch.emitIfChanged(clamped);
    _player._backend.setPitch(clamped);
  }

  /// Dynamically updates the audio output period buffer size in frames.
  Future<void> setBufferSize(int bufferSize) async {
    _player._ensureNotDisposed();
    if (bufferSize < 0) {
      throw ArgumentError.value(
        bufferSize,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    MapLogger.debug('setBufferSize() -> $bufferSize frames');
    _player._bufferSize.emitIfChanged(bufferSize);
    _player._backend.setBufferSize(bufferSize);
  }

  /// Updates all 10 equalizer bands atomically from an [Equalizer] instance.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setEqualizer() -> bands: ${equalizer.toList()}');
    _player._equalizer.emitIfChanged(equalizer);
    _player._backend.setEqualizer(equalizer);
  }

  /// Sets the gain of an individual equalizer band by index (`0` to `9`).
  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinite(gainDb, 'gainDb', 'Gain');
    MapLogger.debug('setEqualizerBand() -> band: $bandIndex, gain: ${gainDb}dB');
    final updated = _player.state.equalizer.withBand(bandIndex, gainDb);
    _player._equalizer.emitIfChanged(updated);
    _player._backend.setEqualizerBand(bandIndex, gainDb);
  }

  /// Switches audio output routing to the specified [AudioDevice].
  Future<void> setDevice(AudioDevice device) async {
    _player._ensureNotDisposed();
    MapLogger.info('setDevice() -> id: ${device.id}, name: ${device.name}');
    final deviceId = (device.isAuto || device.id == 'auto') ? '' : device.id;
    await _player._backend.setDevice(deviceId);
  }

  /// Sets whether playback should automatically pause when the active audio output endpoint changes.
  void setPauseOnDeviceChange(bool enabled) {
    _player._ensureNotDisposed();
    _player._setPauseOnDeviceChange(enabled);
  }

  /// Sets whether silence skipping is enabled, optionally configuring mode and thresholds.
  Future<void> setSkipSilence(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double thresholdDb = -45.0,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    final effectiveMode = enabled
        ? (mode == SilenceSkipMode.disabled ? SilenceSkipMode.continuous : mode)
        : SilenceSkipMode.disabled;

    final current = _player.state.silenceConfig;
    final newConfig = SilenceSkipConfig(
      mode: effectiveMode,
      thresholdDb: thresholdDb,
      minSilenceDuration: minSilenceDuration ?? current.minSilenceDuration,
      padding: padding ?? current.padding,
    );
    await setSilenceConfig(newConfig);
  }

  /// Configures dynamic silence detection and skipping.
  Future<void> setSilenceConfig(SilenceSkipConfig config) async {
    _player._ensureNotDisposed();
    final valid = config.validated();
    MapLogger.debug('setSilenceConfig() -> mode: ${valid.mode}, threshold: ${valid.thresholdDb}dB');
    _player._onSilenceConfig(valid);
    _player._backend.setSilenceSkip(valid);
  }

  /// Enables or disables real-time audio visualizer DSP analysis.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setVisualizerEnabled() -> $enabled');
    _player._setManualVisualizerOverride(enabled);
  }

  /// Clears any manual visualizer override, reverting to reactive on-demand control.
  Future<void> clearVisualizerOverride() async {
    _player._ensureNotDisposed();
    MapLogger.debug('clearVisualizerOverride()');
    _player._setManualVisualizerOverride(null);
  }

  /// Sets replay gain normalization for the track.
  Future<void> setReplayGain({
    required double gainDb,
    double? peak,
    bool preventClipping = true,
  }) async {
    _player._ensureNotDisposed();
    final cfg = ReplayGainConfig(
      enabled: true,
      gainDb: gainDb,
      peak: (peak != null && peak > 0.0) ? peak : 0.0,
      preventClipping: preventClipping,
    );
    MapLogger.debug('setReplayGain() -> gain: ${gainDb}dB, peak: $peak, preventClipping: $preventClipping');
    _player._replayGain.emitIfChanged(cfg);
    _player._backend.setReplayGain(cfg);
  }

  /// Clears replay gain normalization back to unity gain (`0.0 dB`).
  Future<void> clearReplayGain() async {
    _player._ensureNotDisposed();
    MapLogger.debug('clearReplayGain()');
    const cfg = ReplayGainConfig(enabled: false);
    _player._replayGain.emitIfChanged(cfg);
    _player._backend.setReplayGain(cfg);
  }

  /// Sets standalone manual preamp gain in decibels applied prior to the equalizer.
  Future<void> setPreamp(double preampDb) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinite(preampDb, 'preampDb', 'Preamp');
    final clamped = preampDb.clamp(-24.0, 24.0);
    MapLogger.debug('setPreamp() -> ${clamped}dB');
    _player._preamp.emitIfChanged(clamped);
    _player._backend.setPreamp(clamped);
  }

  /// Sets stereo channel balance (`-1.0` full left, `0.0` center, `+1.0` full right).
  Future<void> setBalance(double pan) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinite(pan, 'pan', 'Balance');
    final clamped = pan.clamp(-1.0, 1.0);
    MapLogger.debug('setBalance() -> $clamped');
    _player._balance.emitIfChanged(clamped);
    _player._backend.setBalance(clamped);
  }

  /// Sets whether mono downmix is enabled for accessibility or single speakers.
  Future<void> setMono(bool enabled) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setMono() -> $enabled');
    _player._mono.emitIfChanged(enabled);
    _player._backend.setMono(enabled);
  }

  /// Configures headphone binaural crossfeed (Bauer bs2b).
  Future<void> setCrossfeed(CrossfeedMode mode) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setCrossfeed() -> $mode');
    _player._crossfeed.emitIfChanged(mode);
    _player._backend.setCrossfeed(mode);
  }

  /// Configures the stereo widener / spatializer.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.3,
  }) async {
    _player._ensureNotDisposed();
    _AudioParamValidator.requireFinite(width, 'width', 'Spatializer width');
    final clampedWidth = width.clamp(1.0, 2.0);
    MapLogger.debug('setSpatializer() -> enabled: $enabled, width: $clampedWidth');
    _player._spatializerEnabled.emitIfChanged(enabled);
    _player._spatializerWidth.emitIfChanged(clampedWidth);
    _player._backend.setSpatializer(enabled: enabled, width: clampedWidth);
  }

  /// Enables or disables 3D spatial audio and Doppler shift processing.
  Future<void> setSpatialEnabled(bool enabled) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setSpatialEnabled() -> $enabled');
    _player.spatial.setEnabled(enabled);
  }

  /// Sets the 3D spatial listener state.
  Future<void> setSpatialListener({
    Vector3? position,
    Vector3? velocity,
    Vector3? forward,
    Vector3? up,
  }) async {
    _player._ensureNotDisposed();
    _player.spatial.setListener(
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
    _player._ensureNotDisposed();
    _player.spatial.setEmitter(
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
    _player._ensureNotDisposed();
    _player.spatial.setDopplerFactor(factor);
  }

  /// Sets the medium speed of sound in m/s (default 343.3 m/s).
  Future<void> setSpatialSpeedOfSound(double speed) async {
    _player._ensureNotDisposed();
    _player.spatial.setSpeedOfSound(speed);
  }

  /// Enables or disables the True-Peak soft-knee output limiter protector.
  Future<void> setLimiter(bool enabled) async {
    _player._ensureNotDisposed();
    MapLogger.debug('setLimiter() -> $enabled');
    _player._limiterEnabled.emitIfChanged(enabled);
    _player._backend.setLimiterEnabled(enabled);
  }

  /// Configures studio-grade algorithmic reverberation.
  Future<void> setReverb(Reverb config) async {
    _player._ensureNotDisposed();
    final valid = config.validated();
    MapLogger.debug('setReverb() -> enabled: ${valid.enabled}, roomSize: ${valid.roomSize}');
    _player._reverb.emitIfChanged(valid);
    _player._backend.setReverb(
      enabled: valid.enabled,
      roomSize: valid.roomSize,
      damping: valid.damping,
      width: valid.width,
      wet: valid.wet,
      dry: valid.dry,
    );
  }
}
