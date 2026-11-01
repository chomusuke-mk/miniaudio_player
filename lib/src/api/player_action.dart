// ignore_for_file: prefer_initializing_formals

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
import 'silence_skip_config.dart';

/// Action interface executing asynchronous playback, seeking, volume, and DSP controls.
class PlayerAction {
  final MiniaudioPlayer _player;

  int _openGeneration = 0;
  Completer<void>? _openingCompleter;
  bool _playRequested = false;
  Future<void>? _pendingSeekFuture;
  DartByteProviderBridge? _customBridge;

  PlayerAction(this._player);

  /// Awaits completion of the currently in-flight audio source opening operation.
  Future<void> waitUntilOpen() => _openingCompleter?.future ?? Future.value();

  /// Disposes any active bridge sessions and cancels pending tasks.
  void dispose() {
    _openGeneration++;
    _playRequested = false;
    _pendingSeekFuture = null;
    final bridge = _customBridge;
    _customBridge = null;
    bridge?.dispose();
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openingCompleter!.complete();
    }
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

    try {
      await _player.backend.beginOpen();
    } catch (_) {
      try {
        await _player.backend.stop();
      } catch (_) {}
    }

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

      final failedBridge = _customBridge;
      _customBridge = null;
      failedBridge?.dispose();

      _player.notifyOpenFailed(error);

      if (!completer.isCompleted) {
        completer.future.ignore();
        completer.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  /// Prepares an audio source for playback.
  ///
  /// Accepts an [AudioSource] instance.
  Future<void> open(AudioSource source) async {
    _player.ensureNotDisposed();

    _customBridge?.dispose();
    _customBridge = null;

    return _openGuarded((gen) async {
      switch (source) {
        case UriAudioSource s:
          if (s.sourceString.isEmpty) {
            throw const MiniaudioPlayerException(
              'Cannot open empty source path or URL',
            );
          }
          final str = s.sourceString;
          if (str.startsWith('asset://') || str.startsWith('asset:')) {
            final key = str.startsWith('asset://')
                ? str.substring('asset://'.length)
                : str.substring('asset:'.length);
            final loader = MiniaudioPlayerGlobalConfig.assetLoader;
            if (loader != null) {
              try {
                final bytes = await loader(key);
                await _player.backend.openMemory(bytes);
                return;
              } catch (_) {}
            }
          }
          await _player.backend.openSource(s.sourceString, headers: s.headers);
        case MemoryAudioSource s:
          if (s.bytes.isEmpty) {
            throw const MiniaudioPlayerException('Cannot open empty byte buffer');
          }
          await _player.backend.openMemory(s.bytes);
        case CustomAudioSource s:
          final backend = _player.backend;
          if (backend is NativePlayerBackend) {
            final bridge = DartByteProviderBridge(backend, s.provider);
            _customBridge = bridge;
            await bridge.start();
          } else {
            throw UnimplementedError(
              'CustomAudioSource is only supported on native platforms',
            );
          }
      }
    });
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
      if (_openGeneration != gen || !_playRequested) {
        return;
      }
    }
    if (_pendingSeekFuture != null) {
      try {
        await _pendingSeekFuture;
      } catch (_) {}
    }
    return _executePlay();
  }

  Future<void> _executePlay() async {
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
    return _executePause();
  }

  Future<void> _executePause() async {
    await _player.backend.pause();
  }

  /// Stops audio playback and resets the position to the beginning.
  Future<void> stop() async {
    _player.ensureNotDisposed();
    _pendingSeekFuture = null;
    if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
      _openGeneration++;
      _playRequested = false;
      final bridge = _customBridge;
      _customBridge = null;
      bridge?.dispose();
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

  int _seekGeneration = 0;

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
        if (_openGeneration != gen || _seekGeneration != thisSeekGen) {
          return;
        }
      }
      if (_seekGeneration != thisSeekGen) {
        return;
      }
      return _executeSeek(targetPosition);
    }

    final future = doSeek();
    _pendingSeekFuture = future;
    return future;
  }

  Future<void> _executeSeek(Duration position) async {
    await _player.backend.seek(position);
  }

  /// Sets master volume as a linear amplitude scale from `0.0` (mute) to `1.0` (max volume).
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Volume must be finite and non-negative',
      );
    }
    final clampedVolume = volume.clamp(0.0, 2.0);
    _player.setVolumeSnapshot(clampedVolume);
    _player.backend.setVolume(clampedVolume);
  }

  /// Sets playback speed/rate (`0.1` to `4.0`, where `1.0` is normal).
  ///
  /// Pitch is preserved automatically via high-quality time-stretching.
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    if (rate.isNaN || rate.isInfinite || rate <= 0.0) {
      throw ArgumentError.value(
        rate,
        'rate',
        'Rate must be finite and positive',
      );
    }
    final clampedRate = rate.clamp(0.1, 4.0);
    _player.setRateSnapshot(clampedRate);
    _player.backend.setRate(clampedRate);
  }

  /// Sets playback pitch scale (`0.5` to `2.0`, where `1.0` is original pitch).
  ///
  /// Speed/tempo is preserved automatically.
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite || pitch <= 0.0) {
      throw ArgumentError.value(
        pitch,
        'pitch',
        'Pitch must be finite and positive',
      );
    }
    final clampedPitch = pitch.clamp(0.5, 2.0);
    _player.setPitchSnapshot(clampedPitch);
    _player.backend.setPitch(clampedPitch);
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
    if (bandIndex < 0 || bandIndex >= 10) {
      throw RangeError.range(bandIndex, 0, 9, 'bandIndex');
    }
    if (gainDb.isNaN || gainDb.isInfinite) {
      throw ArgumentError.value(gainDb, 'gainDb', 'Gain must be finite');
    }
    final gains = List<double>.from(_player.state.equalizer.toList());
    gains[bandIndex] = gainDb.clamp(-24.0, 24.0);
    _player.setEqualizerSnapshot(Equalizer.fromList(gains));
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
    final threshold = config.thresholdDb.clamp(-90.0, -10.0);
    final minMs = config.minSilenceDuration.inMilliseconds.clamp(50, 5000);
    final maxPad = minMs ~/ 2;
    final padMs = config.padding.inMilliseconds.clamp(0, maxPad);
    final clampedConfig = SilenceSkipConfig(
      mode: config.mode,
      thresholdDb: threshold,
      minSilenceDuration: Duration(milliseconds: minMs),
      padding: Duration(milliseconds: padMs),
    );
    _player.setSilenceConfigSnapshot(clampedConfig);
    _player.backend.setSilenceSkip(clampedConfig);
  }

  /// Enables or disables real-time audio visualizer DSP analysis in native C.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _player.setManualVisualizerOverride(enabled);
  }

  /// Clears any manual visualizer override, reverting to reactive on-demand
  /// control based on active `player.stream.visualizer` listeners.
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

  /// Clears replay gain normalization back to unity gain (0.0 dB).
  Future<void> clearReplayGain() async {
    _player.ensureNotDisposed();
    const cfg = ReplayGainConfig(enabled: false);
    _player.setReplayGainSnapshot(cfg);
    _player.backend.setReplayGain(cfg);
  }

  /// Sets standalone manual preamp gain in decibels applied prior to the equalizer.
  Future<void> setPreamp(double preampDb) async {
    _player.ensureNotDisposed();
    if (preampDb.isNaN || preampDb.isInfinite) {
      throw ArgumentError.value(preampDb, 'preampDb', 'Preamp must be finite');
    }
    final clamped = preampDb.clamp(-24.0, 24.0);
    _player.setPreampSnapshot(clamped);
    _player.backend.setPreamp(clamped);
  }

  /// Sets stereo channel balance (-1.0 for full left, 0.0 for center, +1.0 for full right).
  Future<void> setBalance(double pan) async {
    _player.ensureNotDisposed();
    if (pan.isNaN || pan.isInfinite) {
      throw ArgumentError.value(pan, 'pan', 'Balance must be finite');
    }
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
    if (width.isNaN || width.isInfinite) {
      throw ArgumentError.value(
        width,
        'width',
        'Spatializer width must be finite',
      );
    }
    final clampedWidth = width.clamp(1.0, 2.0);
    _player.setSpatializerSnapshot(enabled: enabled, width: clampedWidth);
    _player.backend.setSpatializer(
      enabled: enabled,
      width: clampedWidth,
    );
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
    final clamped = Reverb(
      enabled: config.enabled,
      roomSize: config.roomSize.clamp(0.0, 1.0),
      damping: config.damping.clamp(0.0, 1.0),
      width: config.width.clamp(0.0, 1.0),
      wet: config.wet.clamp(0.0, 2.0),
      dry: config.dry.clamp(0.0, 2.0),
    );
    _player.setReverbSnapshot(clamped);
    _player.backend.setReverb(
      enabled: clamped.enabled,
      roomSize: clamped.roomSize,
      damping: clamped.damping,
      width: clamped.width,
      wet: clamped.wet,
      dry: clamped.dry,
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
