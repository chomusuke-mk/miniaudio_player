// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/audio_byte_provider.dart';
import '../loader/unified_audio_loader.dart';
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
  UnifiedAudioLoader? _activeLoader;

  PlayerAction(this._player);

  /// Active unified audio loader instance, if a source is open.
  UnifiedAudioLoader? get activeLoader => _activeLoader;

  /// Disposes any active loader sessions and cancels pending tasks.
  void dispose() {
    _openGeneration++;
    _playRequested = false;
    _pendingSeekFuture = null;
    final loader = _activeLoader;
    _activeLoader = null;
    loader?.dispose();
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

    final prevLoader = _activeLoader;
    _activeLoader = null;

    _player.resetMetadata();
    _player.notifyOpening();

    await prevLoader?.dispose();
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

      final failedLoader = _activeLoader;
      _activeLoader = null;
      await failedLoader?.dispose();

      _player.notifyOpenFailed(error);

      if (!completer.isCompleted) {
        completer.future.ignore();
        completer.completeError(error, stackTrace);
      }
      rethrow;
    }
  }

  Future<void> _startUnifiedLoader(
    AudioByteProvider provider, {
    required int gen,
    required Duration bufferAhead,
    required Duration bufferBehind,
  }) async {
    if (_openGeneration != gen) {
      await provider.close();
      return;
    }
    final loader = UnifiedAudioLoader(
      _player,
      provider: provider,
      bufferAhead: bufferAhead,
      bufferBehind: bufferBehind,
    );
    _activeLoader = loader;
    await loader.start();
  }

  /// Prepares an audio source for playback through the unified loader pipeline.
  ///
  /// Accepts an [AudioSource] instance or a raw source ([String] path/URL,
  /// [Uri], [Uint8List] bytes, [AudioByteProvider], or filesystem entity)
  /// resolved via [AudioSource.uri].
  Future<void> open(
    dynamic source, {
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) async {
    _player.ensureNotDisposed();

    final effectiveAhead = bufferAhead;
    final effectiveBehind = bufferBehind;

    final AudioSource audioSource;
    if (source is AudioSource) {
      audioSource = source;
    } else {
      audioSource = AudioSource.uri(source, bufferAhead: effectiveAhead);
    }

    switch (audioSource) {
      case FileAudioSource s:
        if (s.path.isEmpty) {
          throw const MiniaudioPlayerException('Cannot open empty file path');
        }
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            FileByteProvider(s.path),
            gen: gen,
            bufferAhead: effectiveAhead ?? _player.bufferLocalDuration,
            bufferBehind: effectiveBehind ?? _player.bufferBehindLocalDuration,
          ),
        );

      case AssetAudioSource s:
        if (s.assetKey.isEmpty) {
          throw const MiniaudioPlayerException('Cannot open empty asset path');
        }
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            AssetByteProvider(s.assetKey, package: s.package),
            gen: gen,
            bufferAhead: effectiveAhead ?? _player.bufferLocalDuration,
            bufferBehind: effectiveBehind ?? _player.bufferBehindLocalDuration,
          ),
        );

      case MemoryAudioSource s:
        if (s.bytes.isEmpty) {
          throw const MiniaudioPlayerException('Cannot open empty byte buffer');
        }
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            MemoryByteProvider(s.bytes, uri: s.uri, contentType: s.mimeType),
            gen: gen,
            bufferAhead: effectiveAhead ?? _player.bufferLocalDuration,
            bufferBehind: effectiveBehind ?? _player.bufferBehindLocalDuration,
          ),
        );

      case LiveStreamAudioSource s:
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            LiveStreamByteProvider(
              s.uri,
              headers: s.headers,
              onIcyMetaBytes: setIcyMeta,
            ),
            gen: gen,
            bufferAhead: effectiveAhead ?? s.jitterBuffer,
            bufferBehind: effectiveBehind ??
                _player.bufferBehindLiveStreamDuration,
          ),
        );

      case NetworkAudioSource s:
        final scheme = s.uri.scheme.toLowerCase();
        var uri = s.uri;
        var effectiveIsLive = s.isLive;
        if (scheme == 'icy' || scheme == 'icyx') {
          uri = Uri.parse(
            uri.toString().replaceFirst(
                  RegExp(r'^icyx?://', caseSensitive: false),
                  'http://',
                ),
          );
          effectiveIsLive = true;
        } else if (scheme != 'http' && scheme != 'https' && scheme != 'blob') {
          throw ArgumentError.value(
            s.uri,
            'uri',
            'Invalid URL scheme: "${uri.scheme}" (expected http, https, icy, icyx, or blob)',
          );
        }
        final ahead = effectiveAhead ??
            s.bufferAhead ??
            (effectiveIsLive
                ? _player.bufferLiveStreamDuration
                : _player.bufferNetworkDuration);
        final behind = effectiveBehind ??
            (effectiveIsLive
                ? _player.bufferBehindLiveStreamDuration
                : _player.bufferBehindNetworkDuration);
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            effectiveIsLive
                ? LiveStreamByteProvider(
                    uri,
                    headers: s.headers,
                    onIcyMetaBytes: setIcyMeta,
                  )
                : NetworkByteProvider(
                    uri,
                    headers: s.headers,
                    onIcyMetaBytes: setIcyMeta,
                  ),
            gen: gen,
            bufferAhead: ahead,
            bufferBehind: behind,
          ),
        );

      case ResolvingAudioSource s:
        if (s.rejectedByPathTraversal) {
          return _openGuarded((_) async {
            throw MiniaudioPlayerException(
              'Path traversal rejected in URI: ${s.uri}',
              errorCode: MapResult.errorAccessDenied,
            );
          });
        }
        return _openGuarded((gen) async {
          final resolvingProvider = ResolvingByteProvider(
            s.uri,
            canonicalFilePath: s.canonicalFilePath,
            headers: s.headers,
            isLive: s.isLive,
            ownFd: s.ownFd,
            rejectedByPathTraversal: s.rejectedByPathTraversal,
          );
          final promoted = await resolvingProvider.resolveProvider(
            isCancelled: () => _openGeneration != gen || _player.isDisposed,
          );
          if (_openGeneration != gen || _player.isDisposed) {
            await promoted.close();
            return;
          }
          final ahead = effectiveAhead ??
              s.bufferAhead ??
              (promoted.isLiveStream
                  ? _player.bufferLiveStreamDuration
                  : (promoted.isNetwork
                      ? _player.bufferNetworkDuration
                      : _player.bufferLocalDuration));
          final behind = effectiveBehind ??
              (promoted.isLiveStream
                  ? _player.bufferBehindLiveStreamDuration
                  : (promoted.isNetwork
                      ? _player.bufferBehindNetworkDuration
                      : _player.bufferBehindLocalDuration));
          await _startUnifiedLoader(
            promoted,
            gen: gen,
            bufferAhead: ahead,
            bufferBehind: behind,
          );
        });

      case CustomAudioSource s:
        if (s.provider.sourceId.trim().isEmpty) {
          throw const MiniaudioPlayerException(
            'Cannot open provider with empty sourceId',
          );
        }
        final ahead = effectiveAhead ??
            (s.provider.isLiveStream
                ? _player.bufferLiveStreamDuration
                : (s.provider.isNetwork
                    ? _player.bufferNetworkDuration
                    : _player.bufferLocalDuration));
        final behind = effectiveBehind ??
            (s.provider.isLiveStream
                ? _player.bufferBehindLiveStreamDuration
                : (s.provider.isNetwork
                    ? _player.bufferBehindNetworkDuration
                    : _player.bufferBehindLocalDuration));
        return _openGuarded(
          (gen) => _startUnifiedLoader(
            s.provider,
            gen: gen,
            bufferAhead: ahead,
            bufferBehind: behind,
          ),
        );
    }
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
    if (_activeLoader != null && _activeLoader!.isStopped) {
      await _activeLoader!.onPlayFromStopped();
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
      final loader = _activeLoader;
      _activeLoader = null;
      await loader?.dispose();
      try {
        await _player.backend.stop();
      } catch (_) {}
      if (!_openingCompleter!.isCompleted) {
        _openingCompleter!.complete();
      }
      _player.notifyStopped();
      return;
    }
    await _activeLoader?.stop();
    await _player.backend.stop();
  }

  /// Seeks to the specified [position].
  Future<void> seek(Duration position) {
    _player.ensureNotDisposed();
    final targetPosition = position < Duration.zero ? Duration.zero : position;

    Future<void> doSeek() async {
      if (_openingCompleter != null && !_openingCompleter!.isCompleted) {
        final gen = _openGeneration;
        try {
          await _openingCompleter!.future;
        } catch (_) {
          return;
        }
        if (_openGeneration != gen) {
          return;
        }
      }
      return _executeSeek(targetPosition);
    }

    final future = doSeek();
    _pendingSeekFuture = future;
    return future;
  }

  Future<void> _executeSeek(Duration position) async {
    if (_activeLoader != null) {
      await _activeLoader!.seek(position);
    } else {
      await _player.backend.seek(position);
    }
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
