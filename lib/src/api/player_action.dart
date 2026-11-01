import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/custom_byte_provider.dart';
import '../platform/native/native_backend.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'dsp_config.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'player_state.dart' show PlaybackState;
import 'silence_skip_config.dart';
import 'spatial.dart';

/// Deterministic numeric validator for audio and DSP parameters.
abstract final class _AudioParamValidator {
  static void requireFinite(double value, String name, String label) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError.value(value, name, '$label must be finite');
    }
  }

  static void requireFiniteNonNegative(double value, String name, String label) {
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

  PlayerAction(this._player);

  /// Awaits completion of the currently in-flight audio source opening operation.
  Future<void> waitUntilOpen() => _openingCompleter?.future ?? Future.value();

  /// Disposes any active bridge sessions and cancels pending tasks.
  void dispose() {
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
    _player.ensureNotDisposed();

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

    _player.resetMetadata();
    _player.notifyOpening();

    prevBridge?.dispose();
    if (_openGeneration != gen || _player.isDisposed) return;

    await _resetBackendForOpen();
    if (_openGeneration != gen || _player.isDisposed) return;

    try {
      await openTask(gen);
      if (_openGeneration != gen) return;

      _player.notifyOpenCompleted();
      if (!completer.isCompleted) {
        completer.complete();
      }
    } catch (error, stackTrace) {
      if (_openGeneration != gen) return;

      _disposeCustomBridge();
      _player.notifyOpenFailed(error);

      if (!completer.isCompleted) {
        completer.future.ignore();
        completer.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<void> _resetBackendForOpen() async {
    try {
      await _player.backend.beginOpen();
    } catch (_) {
      try {
        await _player.backend.stop();
      } catch (_) {}
    }
  }

  /// Prepares an audio source for playback.
  Future<void> open(AudioSource source) async {
    _player.ensureNotDisposed();
    _currentSource = source;
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
    final assetBytes = await _tryLoadFlutterAsset(str);
    if (assetBytes != null) {
      await _player.backend.openMemory(assetBytes);
      return;
    }
    await _player.backend.openSource(str, headers: source.headers);
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
    await _player.backend.openMemory(source.bytes);
  }

  Future<void> _openCustomSource(CustomAudioSource source) async {
    final backend = _player.backend;
    if (backend is! NativePlayerBackend) {
      throw UnimplementedError(
        'CustomAudioSource is only supported on native platforms',
      );
    }
    final bridge = DartByteProviderBridge(backend, source.provider);
    _customBridge = bridge;
    await bridge.start();
  }

  /// Starts or resumes audio playback.
  Future<void> play() async {
    _player.ensureNotDisposed();
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
    if (_player.state.trackMetadata?.isLiveStream == true &&
        _player.state.playbackState == PlaybackState.stopped &&
        _currentSource != null) {
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
    await _player.backend.play();
  }

  /// Pauses audio playback at the current position.
  Future<void> pause() async {
    _player.ensureNotDisposed();
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _playRequested = false;
      return;
    }
    await _player.backend.pause();
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    _player.ensureNotDisposed();
    _pendingSeekFuture = null;
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openGeneration++;
      _playRequested = false;
      _disposeCustomBridge();
      try {
        await _player.backend.stop();
      } catch (_) {}
      if (!_openingCompleter!.isCompleted) {
        _openingCompleter!.complete();
      }
      _player.notifyStopped();
      return;
    }
    await _player.backend.stop();
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) {
    _player.ensureNotDisposed();
    final targetPosition = position < Duration.zero ? Duration.zero : position;
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
    await _player.backend.seek(position);
  }

  /// Sets master volume as a linear amplitude scale (`0.0` to `2.0`).
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFiniteNonNegative(volume, 'volume', 'Volume');
    final clamped = volume.clamp(0.0, 2.0);
    _player.setVolumeSnapshot(clamped);
    _player.backend.setVolume(clamped);
  }

  /// Sets playback speed/rate (`0.1` to `4.0`, where `1.0` is normal).
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinitePositive(rate, 'rate', 'Rate');
    final clamped = rate.clamp(0.1, 4.0);
    _player.setRateSnapshot(clamped);
    _player.backend.setRate(clamped);
  }

  /// Sets playback pitch scale (`0.5` to `2.0`, where `1.0` is original pitch).
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinitePositive(pitch, 'pitch', 'Pitch');
    final clamped = pitch.clamp(0.5, 2.0);
    _player.setPitchSnapshot(clamped);
    _player.backend.setPitch(clamped);
  }

  /// Dynamically updates the audio output period buffer size in frames.
  Future<void> setBufferSize(int bufferSize) async {
    _player.ensureNotDisposed();
    if (bufferSize < 0) {
      throw ArgumentError.value(
        bufferSize,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    _player.setBufferSizeSnapshot(bufferSize);
    _player.backend.setBufferSize(bufferSize);
  }

  /// Updates all 10 equalizer bands atomically from an [Equalizer] instance.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player.ensureNotDisposed();
    _player.setEqualizerSnapshot(equalizer);
    _player.backend.setEqualizer(equalizer);
  }

  /// Sets the gain of an individual equalizer band by index (`0` to `9`).
  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinite(gainDb, 'gainDb', 'Gain');
    final updated = _player.state.equalizer.withBand(bandIndex, gainDb);
    _player.setEqualizerSnapshot(updated);
    _player.backend.setEqualizerBand(bandIndex, gainDb);
  }

  /// Switches audio output routing to the specified [AudioDevice].
  Future<void> setDevice(AudioDevice device) async {
    _player.ensureNotDisposed();
    final deviceId = (device.isAuto || device.id == 'auto') ? '' : device.id;
    await _player.backend.setDevice(deviceId);
  }

  /// Sets whether playback should automatically pause when the active audio output endpoint changes.
  void setPauseOnDeviceChange(bool enabled) {
    _player.ensureNotDisposed();
    _player.setPauseOnDeviceChangeInternal(enabled);
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
    _player.ensureNotDisposed();
    final valid = config.validated();
    _player.setSilenceConfigSnapshot(valid);
    _player.backend.setSilenceSkip(valid);
  }

  /// Enables or disables real-time audio visualizer DSP analysis.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _player.setManualVisualizerOverride(enabled);
  }

  /// Clears any manual visualizer override, reverting to reactive on-demand control.
  Future<void> clearVisualizerOverride() async {
    _player.ensureNotDisposed();
    _player.setManualVisualizerOverride(null);
  }

  /// Sets replay gain normalization for the track.
  Future<void> setReplayGain({
    required double gainDb,
    double? peak,
    bool preventClipping = true,
  }) async {
    _player.ensureNotDisposed();
    final cfg = ReplayGainConfig(
      enabled: true,
      gainDb: gainDb,
      peak: (peak != null && peak > 0.0) ? peak : 0.0,
      preventClipping: preventClipping,
    );
    _player.setReplayGainSnapshot(cfg);
    _player.backend.setReplayGain(cfg);
  }

  /// Clears replay gain normalization back to unity gain (`0.0 dB`).
  Future<void> clearReplayGain() async {
    _player.ensureNotDisposed();
    const cfg = ReplayGainConfig(enabled: false);
    _player.setReplayGainSnapshot(cfg);
    _player.backend.setReplayGain(cfg);
  }

  /// Sets standalone manual preamp gain in decibels applied prior to the equalizer.
  Future<void> setPreamp(double preampDb) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinite(preampDb, 'preampDb', 'Preamp');
    final clamped = preampDb.clamp(-24.0, 24.0);
    _player.setPreampSnapshot(clamped);
    _player.backend.setPreamp(clamped);
  }

  /// Sets stereo channel balance (`-1.0` full left, `0.0` center, `+1.0` full right).
  Future<void> setBalance(double pan) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinite(pan, 'pan', 'Balance');
    final clamped = pan.clamp(-1.0, 1.0);
    _player.setBalanceSnapshot(clamped);
    _player.backend.setBalance(clamped);
  }

  /// Sets whether mono downmix is enabled for accessibility or single speakers.
  Future<void> setMono(bool enabled) async {
    _player.ensureNotDisposed();
    _player.setMonoSnapshot(enabled);
    _player.backend.setMono(enabled);
  }

  /// Configures headphone binaural crossfeed (Bauer bs2b).
  Future<void> setCrossfeed(CrossfeedMode mode) async {
    _player.ensureNotDisposed();
    _player.setCrossfeedSnapshot(mode);
    _player.backend.setCrossfeed(mode);
  }

  /// Configures the stereo widener / spatializer.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.3,
  }) async {
    _player.ensureNotDisposed();
    _AudioParamValidator.requireFinite(width, 'width', 'Spatializer width');
    final clampedWidth = width.clamp(1.0, 2.0);
    _player.setSpatializerSnapshot(enabled: enabled, width: clampedWidth);
    _player.backend.setSpatializer(enabled: enabled, width: clampedWidth);
  }

  /// Enables or disables 3D spatial audio and Doppler shift processing.
  Future<void> setSpatialEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _player.spatial.setEnabled(enabled);
  }

  /// Sets the 3D spatial listener state.
  Future<void> setSpatialListener({
    Vector3? position,
    Vector3? velocity,
    Vector3? forward,
    Vector3? up,
  }) async {
    _player.ensureNotDisposed();
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
    _player.ensureNotDisposed();
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
    _player.ensureNotDisposed();
    _player.spatial.setDopplerFactor(factor);
  }

  /// Sets the medium speed of sound in m/s (default 343.3 m/s).
  Future<void> setSpatialSpeedOfSound(double speed) async {
    _player.ensureNotDisposed();
    _player.spatial.setSpeedOfSound(speed);
  }

  /// Enables or disables the True-Peak soft-knee output limiter protector.
  Future<void> setLimiter(bool enabled) async {
    _player.ensureNotDisposed();
    _player.setLimiterSnapshot(enabled);
    _player.backend.setLimiterEnabled(enabled);
  }

  /// Configures studio-grade algorithmic reverberation.
  Future<void> setReverb(Reverb config) async {
    _player.ensureNotDisposed();
    final valid = config.validated();
    _player.setReverbSnapshot(valid);
    _player.backend.setReverb(
      enabled: valid.enabled,
      roomSize: valid.roomSize,
      damping: valid.damping,
      width: valid.width,
      wet: valid.wet,
      dry: valid.dry,
    );
  }

  /// Sets dynamic ICY livestream metadata received over network.
  void setIcyMeta(Uint8List data) {
    _player.ensureNotDisposed();
    if (data.isEmpty) return;
    _player.backend.setIcyMeta(data);
    _player.checkMetaBytesUpdated();
  }

  /// Probes tail metadata (ID3v1, APEv2, MP4 moov, etc.) directly into buffer Tail.
  void probeTail(Uint8List data, int tailOffset) {
    _player.ensureNotDisposed();
    if (data.isEmpty) return;
    _player.backend.probeTail(data, tailOffset);
    _player.checkMetaBytesUpdated();
  }
}
