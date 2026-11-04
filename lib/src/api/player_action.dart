import 'dart:async';
import 'dart:typed_data' hide Int64List;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;

import '../equalizer.dart';
import '../reverb.dart';
import '../rust/api/player.dart' as rust;
import '../rust/api/types.dart' as rust_types;
import 'audio_device.dart';
import 'audio_source.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'logger.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'player_models.dart';
import 'player_state.dart';
import 'recording.dart' show DuckingConfig;
import 'silence_skip_config.dart';
import 'spatial.dart';

/// Action interface executing asynchronous playback, queue, effects, and DSP controls.
///
/// In strict accordance with the stream-driven architecture, actions dispatch commands
/// to Rust via FFI and NEVER emit artificial state in Dart. The native Rust event pipeline
/// is the authoritative source for all state transitions and telemetry.
class PlayerAction<T> {
  final MiniaudioPlayer<T> _player;

  PlayerAction(this._player);

  rust.RustMiniaudioPlayer get _rust => _player.rustPlayer;

  Future<void> _commandTail = Future.value();

  Future<R> _serialize<R>(Future<R> Function() action) {
    final completer = Completer<R>();
    _commandTail = _commandTail.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  bool _volumeNormalization = true;
  double _defaultReplayGain = 0.0;
  double? _forcedReplayGain;
  ReplayGainMode _replayGainMode = ReplayGainMode.track;

  double? _effectiveReplayGain(AudioSource<dynamic> source) {
    if (!_volumeNormalization) return null;
    if (_replayGainMode == ReplayGainMode.forced && _forcedReplayGain != null) {
      return _forcedReplayGain;
    }
    return source.replayGainDb ??
        (_defaultReplayGain != 0.0 ? _defaultReplayGain : null);
  }

  rust_types.RustAudioSource _toRustSource(
    AudioSource<dynamic> s,
    int id, [
    Uint8List? initBytes,
  ]) {
    final gain = _effectiveReplayGain(s);
    if (s is CustomAudioSource<T>) {
      final streamId = s.provider.streamId != 0 ? s.provider.streamId : id;
      final url = s.provider.totalBytes != null
          ? 'custom://$streamId?size=${s.provider.totalBytes}'
          : 'custom://$streamId';
      return rust_types.RustAudioSource(
        id: id,
        source: url,
        dataBytes: initBytes,
        replayGainDb: gain,
        replayPeak: s.replayPeak,
      );
    }
    final raw = s.toRustSource(id);
    return rust_types.RustAudioSource(
      id: raw.id,
      source: raw.source,
      headers: raw.headers,
      dataBytes: raw.dataBytes,
      replayGainDb: gain,
      replayPeak: raw.replayPeak,
    );
  }

  (AudioSource<T> retained, rust_types.RustAudioSource rustSource) _prepareSource(
    AudioSource<T> s, [
    Uint8List? customInitBytes,
  ]) {
    final uniqueId = s.id ?? _player.nextSourceId++;
    s.attachEngineId(uniqueId);

    final rustSource = _toRustSource(s, uniqueId, customInitBytes);

    final AudioSource<T> retained;
    if (s is MemoryAudioSource<T>) {
      // Transfer byte payload ownership exclusively to Rust. Dart retains a lightweight
      // descriptor without holding the large Uint8List buffer in memory.
      retained = MemoryAudioSource<T>(
        Uint8List(0),
        data: s.data,
        replayGainDb: s.replayGainDb,
        replayPeak: s.replayPeak,
        internalId: uniqueId,
      );
    } else if (s is CustomAudioSource<T>) {
      _player.customProviders[uniqueId] = s.provider;
      if (s.provider.streamId != 0) {
        _player.customProviders[s.provider.streamId] = s.provider;
      }
      retained = s.copyWith(id: uniqueId);
    } else {
      retained = s.copyWith(id: uniqueId);
    }

    _player.sourceRegistry[uniqueId] = retained;
    return (retained, rustSource);
  }

  // =========================================================================
  // Master Transport Controls
  // =========================================================================

  /// Starts or resumes audio playback.
  Future<void> play() => _serialize(() async {
    _player.ensureNotDisposed();
    MapLogger.info('play() requested');
    if (_player.state.phase == EnginePhase.completed ||
        _player.state.isCompleted) {
      _rust.skipToIndex(index: BigInt.zero);
    }
    _rust.play();
    _player.checkInfiniteMix();
    await Future<void>.delayed(Duration.zero);
  });

  /// Pauses audio playback at current position.
  Future<void> pause() => _serialize(() async {
    _player.ensureNotDisposed();
    MapLogger.info('pause() requested');
    _rust.pause();
    await Future<void>.delayed(Duration.zero);
  });

  /// Stops playback and rewinds position to zero.
  Future<void> stop() => _serialize(() async {
    _player.ensureNotDisposed();
    MapLogger.info('stop() requested');
    _rust.stop();
    await Future<void>.delayed(Duration.zero);
  });

  /// Seeks to specified position in the currently playing track.
  Future<void> seek(Duration position) => _serialize(() async {
    _player.ensureNotDisposed();
    final targetPosition = position < Duration.zero ? Duration.zero : position;
    MapLogger.info('seek() requested -> ${targetPosition.inMilliseconds}ms');
    _rust.seek(positionMs: targetPosition.inMilliseconds);
    await Future<void>.delayed(Duration.zero);
  });

  Completer<void>? _openingCompleter;

  /// Awaits completion of any pending opening operations.
  Future<void> waitUntilOpen() => _openingCompleter?.future ?? Future.value();

  // =========================================================================
  // Playlist Queue Management
  // =========================================================================

  /// Opens an audio source playlist, replacing the current queue.
  ///
  /// In strict accordance with the stream-driven architecture, this method passes the
  /// sources directly to the native audio engine without performing file I/O, parsing,
  /// or emitting artificial state transitions in Dart.
  Future<void> open(
    List<AudioSource<T>> source, {
    int startIndex = 0,
    bool autoPlay = false,
  }) {
    final completer = Completer<void>();
    _openingCompleter = completer;

    return _serialize(() async {
      _player.ensureNotDisposed();

      try {
        if (source.length == 1) {
          MapLogger.info('open() requested for source: ${source.first}');
        } else {
          MapLogger.info(
            'open() requested for source: ${source.length} items (startIndex: $startIndex, autoPlay: $autoPlay)',
          );
        }

        final normalized = <AudioSource<T>>[];
        final rustSources = <rust_types.RustAudioSource>[];
        for (var i = 0; i < source.length; i++) {
          final s = source[i];
          Uint8List? initBytes;
          if (s is CustomAudioSource<T>) {
            initBytes = await s.provider.readInitialBytes();
          }
          final (retained, rustSource) = _prepareSource(s, initBytes);
          normalized.add(retained);
          rustSources.add(rustSource);
        }
        _player.shadowQueue = List.of(normalized);

        try {
          await _rust.open(
            queue: rustSources,
            startIndex: BigInt.from(startIndex),
            autoPlay: autoPlay,
          );
        } catch (e) {
          if (e is MiniaudioPlayerException) rethrow;
          throw MiniaudioPlayerException.fromRustError(e);
        }

        await applyCurrentTrackReplayGain();

        if (autoPlay) {
          _player.checkInfiniteMix();
        }
      } finally {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (!completer.isCompleted) {
          completer.complete();
        }
      }
    });
  }

  /// Appends tracks to the end of the current playlist queue.
  Future<void> append(List<AudioSource<T>> sources) async {
    _player.ensureNotDisposed();
    if (sources.isEmpty) return;

    final normalized = <AudioSource<T>>[];
    final rustSources = <rust_types.RustAudioSource>[];
    for (final s in sources) {
      final (retained, rustSource) = _prepareSource(s);
      normalized.add(retained);
      rustSources.add(rustSource);
    }
    _player.shadowQueue.addAll(normalized);
    _player.state.queue = List.of(_player.shadowQueue);
    _rust.append(sources: rustSources);
  }

  /// Inserts a track immediately after the active playing track.
  Future<void> insertNext(AudioSource<T> source) async {
    _player.ensureNotDisposed();
    final (retained, rustSource) = _prepareSource(source);
    final curIdx = _player.state.currentIndex;
    final insertIdx = (curIdx >= 0) ? curIdx + 1 : _player.shadowQueue.length;
    _player.shadowQueue.insert(insertIdx, retained);
    _player.state.queue = List.of(_player.shadowQueue);
    _rust.insertNext(source: rustSource);
  }

  /// Removes a track at [index] from the playlist queue.
  Future<void> removeAt(int index) async {
    _player.ensureNotDisposed();
    if (index >= 0 && index < _player.shadowQueue.length) {
      final removed = _player.shadowQueue.removeAt(index);
      if (removed.id != null) {
        _player.sourceRegistry.remove(removed.id);
        _player.customProviders.remove(removed.id);
      }
      _player.state.queue = List.of(_player.shadowQueue);
      _rust.removeAt(index: BigInt.from(index));
    }
  }

  /// Reorders a track from [oldIndex] to [newIndex] within the queue.
  Future<void> reorder(int oldIndex, int newIndex) async {
    _player.ensureNotDisposed();
    if (oldIndex >= 0 &&
        oldIndex < _player.shadowQueue.length &&
        newIndex >= 0 &&
        newIndex < _player.shadowQueue.length) {
      final item = _player.shadowQueue.removeAt(oldIndex);
      _player.shadowQueue.insert(newIndex, item);
      _player.state.queue = List.of(_player.shadowQueue);
      final ids = _player.shadowQueue.map((s) => s.id ?? 0).toList();
      _rust.reorderByIds(ids: Int64List.fromList(ids));
    }
  }

  /// Reorders the playlist queue using an ordered list of unique track [ids].
  Future<void> reorderByIds(List<int> ids) async {
    _player.ensureNotDisposed();
    final idMap = {for (final s in _player.shadowQueue) s.id: s};
    final reordered = <AudioSource<T>>[];
    for (final id in ids) {
      final s = idMap[id];
      if (s != null) reordered.add(s);
    }
    if (reordered.length == _player.shadowQueue.length) {
      _player.shadowQueue = reordered;
      _player.state.queue = List.of(_player.shadowQueue);
    }
    _rust.reorderByIds(ids: Int64List.fromList(ids));
  }

  /// Clears the playlist queue. If [keepCurrent] is true, retains the playing track.
  Future<void> clearQueue({bool keepCurrent = false}) async {
    _player.ensureNotDisposed();
    if (keepCurrent &&
        _player.shadowQueue.isNotEmpty &&
        _player.state.currentIndex >= 0 &&
        _player.state.currentIndex < _player.shadowQueue.length) {
      final cur = _player.shadowQueue[_player.state.currentIndex];
      _player.shadowQueue = [cur];
      final curId = cur.id;
      _player.sourceRegistry.removeWhere((id, _) => id != curId);
      _player.customProviders.removeWhere((id, _) => id != curId);
    } else {
      _player.shadowQueue.clear();
      _player.sourceRegistry.clear();
      _player.customProviders.clear();
    }
    _player.state.queue = List.of(_player.shadowQueue);
    _rust.clearQueue(keepCurrent: keepCurrent);
  }

  /// Advances to the next track in the playlist queue.
  Future<void> next({Duration? crossfadeDuration}) => _serialize(() async {
    _player.ensureNotDisposed();
    await _rust.next(
      crossfadeDurationMs: crossfadeDuration != null
          ? BigInt.from(crossfadeDuration.inMilliseconds)
          : null,
    );
    await applyCurrentTrackReplayGain();
    _player.checkInfiniteMix();
    await Future<void>.delayed(Duration.zero);
  });

  /// Skips back to the previous track, or start of current track if > 3s played.
  Future<void> previous() => _serialize(() async {
    _player.ensureNotDisposed();
    await _rust.previous();
    await applyCurrentTrackReplayGain();
    _player.checkInfiniteMix();
    await Future<void>.delayed(Duration.zero);
  });

  /// Skips directly to track at [index] in the playlist queue.
  Future<void> skipToIndex(int index, {Duration? crossfadeDuration}) =>
      _serialize(() async {
        _player.ensureNotDisposed();
        await _rust.skipToIndex(
          index: BigInt.from(index),
          crossfadeDurationMs: crossfadeDuration != null
              ? BigInt.from(crossfadeDuration.inMilliseconds)
              : null,
        );
        await applyCurrentTrackReplayGain();
        _player.checkInfiniteMix();
        await Future<void>.delayed(Duration.zero);
      });

  /// Configures playlist repeat mode ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  Future<void> setLoopMode(LoopMode mode) async {
    _player.ensureNotDisposed();
    _rust.setLoopMode(mode: mode.index);
    await Future<void>.delayed(Duration.zero);
  }

  /// Enables or disables non-destructive shuffle on the playlist queue.
  Future<void> setShuffle(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setShuffle(enabled: enabled);
    await Future<void>.delayed(Duration.zero);
  }

  /// Configures infinite queue replenishment when playback reaches the end of the queue.
  Future<void> setInfiniteMix(
    bool enabled, {
    InfiniteMixProvider<T>? provider,
  }) async {
    _player.ensureNotDisposed();
    _player.infiniteMixEnabled = enabled;
    if (provider != null) {
      _player.infiniteMixProvider = provider;
    }
    _player.checkInfiniteMix();
  }

  /// Configures crossfade duration and curve between queue tracks.
  Future<void> setCrossfade(CrossfadeConfig config) async {
    _player.ensureNotDisposed();
    _rust.setCrossfade(
      config: rust_types.RustCrossfadeConfig(
        autoDurationMs: BigInt.from(
          config.autoDuration.inMilliseconds < 0 ? 0 : config.autoDuration.inMilliseconds,
        ),
        manualDurationMs: BigInt.from(
          config.manualDuration.inMilliseconds < 0 ? 0 : config.manualDuration.inMilliseconds,
        ),
        curve: config.curve == CrossfadeCurve.linear ? 1 : 0,
      ),
    );
  }

  // =========================================================================
  // Audio Modulation & DSP Controls
  // =========================================================================

  /// Modulates master audio volume. Validations happen in Rust backend.
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    MapLogger.info('setVolume() -> $volume');
    _rust.setVolume(volume: volume.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Modulates playback rate multiplier preserving pitch.
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    _rust.setRate(rate: rate.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Modulates musical pitch multiplier.
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    _rust.setPitch(pitch: pitch.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets stereo balance / pan (-1.0 left to +1.0 right).
  Future<void> setBalance(double balance) async {
    _player.ensureNotDisposed();
    _rust.setBalance(balance: balance.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Toggles monophonic downmixing of stereo channels.
  Future<void> setMono(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setMono(enabled: enabled);
    await Future<void>.delayed(Duration.zero);
  }

  /// Applies 10-band ISO peaking equalizer configuration.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player.ensureNotDisposed();
    _rust.setEqualizer(
      params: rust_types.RustEqualizerParams(
        gains: Float32List.fromList(equalizer.toList()),
        enabled: true,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures algorithmic studio reverberation.
  Future<void> setReverb(Reverb reverb) async {
    _player.ensureNotDisposed();
    _rust.setReverb(
      params: rust_types.RustReverbParams(
        roomSize: reverb.roomSize,
        damping: reverb.damping,
        wet: reverb.wet,
        dry: reverb.dry,
        width: reverb.width,
        mode: 0.0,
        enabled: reverb.enabled,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Toggles master True-Peak brickwall limiter protector.
  Future<void> setLimiter(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setLimiter(enabled: enabled);
    await Future<void>.delayed(Duration.zero);
  }

  /// Enables or disables real-time 10-band FFT spectrum visualizer calculation in the native engine.
  ///
  /// For events to be emitted across [PlayerStream.visualizer], this must be set to `true`.
  /// Defaults to `false`.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setVisualizerEnabled(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Enables or disables raw metadata dispatch from the native audio engine.
  ///
  /// When enabled, raw metadata bytes (e.g. ID3, Vorbis, ICY stream metadata) are emitted
  /// across [PlayerStream.metaBytes] and stored in [PlayerState.metaBytes].
  ///
  /// Defaults to `false` to avoid saturating the event bus.
  Future<void> setMetaBytesEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setMetabytesEnabled(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures intelligent silence detection and skipping.
  Future<void> setSkipSilence(dynamic configOrEnabled) async {
    _player.ensureNotDisposed();
    final SilenceSkipConfig config;
    if (configOrEnabled is bool) {
      config = configOrEnabled
          ? const SilenceSkipConfig.continuous()
          : const SilenceSkipConfig(mode: SilenceSkipMode.disabled);
    } else if (configOrEnabled is SilenceSkipConfig) {
      config = configOrEnabled;
    } else {
      throw ArgumentError(
          'Expected bool or SilenceSkipConfig, got $configOrEnabled');
    }

    _rust.setSkipSilence(
      config: rust_types.RustSilenceConfig(
        thresholdDb: config.thresholdDb,
        minSilenceDurationMs: config.minSilenceDuration.inMilliseconds,
        paddingMs: config.padding.inMilliseconds,
        enabled: config.mode != SilenceSkipMode.disabled,
        mode: config.mode.value,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets detailed silence skipping configuration.
  Future<void> setSilenceConfig(SilenceSkipConfig config) =>
      setSkipSilence(config);

  /// Configures ReplayGain / EBU R128 track loudness normalization.
  Future<void> setReplayGain({
    ReplayGainConfig? config,
    double? gainDb,
    double? peak,
    bool preventClipping = true,
    bool enabled = true,
    bool force = false,
  }) async {
    _player.ensureNotDisposed();
    final effEnabled = config?.enabled ?? enabled;
    final effGain = config?.gainDb ?? gainDb ?? 0.0;
    final effPeak = config?.peak ?? peak ?? 0.0;
    final effPrevent = config?.preventClipping ?? preventClipping;
    _rust.setReplayGain(
      config: rust_types.RustReplayGainConfig(
        gainDb: effGain,
        peak: effPeak,
        preventClipping: effPrevent,
        enabled: effEnabled,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Clears active ReplayGain track normalization.
  Future<void> clearReplayGain() async {
    _player.ensureNotDisposed();
    await setReplayGain(enabled: false);
  }

  /// Sets preamplifier gain in decibels.
  Future<void> setPreamp(double preampDb) async {
    _player.ensureNotDisposed();
    _rust.setPreamp(preampDb: preampDb.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets binaural crossfeed mode.
  Future<void> setCrossfeed(CrossfeedMode mode) async {
    _player.ensureNotDisposed();
    _rust.setCrossfeed(mode: mode.index);
    await Future<void>.delayed(Duration.zero);
  }

  /// Configures stereo widener spatializer.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.0,
  }) async {
    _player.ensureNotDisposed();
    _rust.setSpatializer(enabled: enabled, width: width.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets default ReplayGain fallback.
  Future<void> setDefaultReplayGain(double gainDb) async {
    _player.ensureNotDisposed();
    _defaultReplayGain = gainDb;
    _player.state.defaultReplayGain = gainDb;
    await applyCurrentTrackReplayGain();
  }

  /// Sets forced ReplayGain override.
  Future<void> setForcedReplayGain(double? gainDb) async {
    _player.ensureNotDisposed();
    _forcedReplayGain = gainDb;
    _replayGainMode =
        gainDb != null ? ReplayGainMode.forced : ReplayGainMode.track;
    _player.state.forcedReplayGain = gainDb ?? 0.0;
    _player.state.replayGainMode = _replayGainMode;
    await applyCurrentTrackReplayGain();
  }

  /// Sets ReplayGain calculation mode.
  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    _player.ensureNotDisposed();
    _replayGainMode = mode;
    _player.state.replayGainMode = mode;
    await applyCurrentTrackReplayGain();
  }

  /// Toggles automatic ReplayGain loudness normalization.
  Future<void> setVolumeNormalization(bool enabled) async {
    _player.ensureNotDisposed();
    _volumeNormalization = enabled;
    _player.state.volumeNormalization = enabled;
    await applyCurrentTrackReplayGain();
  }

  /// Applies ReplayGain settings for the currently active track.
  Future<void> applyCurrentTrackReplayGain() async {
    if (!_volumeNormalization) {
      _rust.setReplayGain(
        config: const rust_types.RustReplayGainConfig(
          gainDb: 0.0,
          peak: 1.0,
          preventClipping: true,
          enabled: false,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      return;
    }
    double effectiveGain = 0.0;
    double effectivePeak = 1.0;
    if (_replayGainMode == ReplayGainMode.forced && _forcedReplayGain != null) {
      effectiveGain = _forcedReplayGain!;
    } else {
      final curItem = _player.state.currentItem;
      if (curItem?.replayGainDb != null) {
        effectiveGain = curItem!.replayGainDb!;
        effectivePeak = curItem.replayPeak ?? 1.0;
      } else {
        effectiveGain = _defaultReplayGain;
      }
    }
    _rust.setReplayGain(
      config: rust_types.RustReplayGainConfig(
        gainDb: effectiveGain,
        peak: effectivePeak,
        preventClipping: true,
        enabled: effectiveGain != 0.0,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures resilience behavior when audio playback devices change.
  Future<void> setPauseOnDeviceChange(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setPauseOnDeviceChange(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Switches primary audio playback to [device].
  Future<void> setDevice(AudioDevice device) async {
    _player.ensureNotDisposed();
    if (device.isAuto) {
      await configureOutputs([const AudioOutput.speaker()]);
    } else {
      await configureOutputs([AudioOutput.device(device.id)]);
    }
  }

  /// Updates playback buffer period size.
  Future<void> setBufferSize(int size) async {
    _player.ensureNotDisposed();
    if (size < 0) {
      throw ArgumentError.value(
          size, 'bufferSize', 'Buffer size must be non-negative');
    }
    _rust.setBufferSize(bufferSizeFrames: size);
    await Future<void>.delayed(Duration.zero);
  }

  // =========================================================================
  // RAM Sound Effects Management
  // =========================================================================

  /// Loads and decodes an [AudioEffect] into fast preallocated RAM.
  Future<void> loadEffect(AudioEffect effect) async {
    _player.ensureNotDisposed();
    final rustSource = _toRustSource(effect.source, 0);
    await _rust.loadEffect(
      id: effect.id,
      source: rustSource,
      maxPolyphony: BigInt.from(effect.maxPolyphony),
      pinned: effect.pinned,
    );
    _player.state.loadedEffectIds = _rust.getLoadedEffectIds();
    _player.state.allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
  }

  /// Unloads a cached sound effect from RAM.
  Future<void> unloadEffect(String id) async {
    _player.ensureNotDisposed();
    _rust.unloadEffect(id: id);
    _player.state.loadedEffectIds = _rust.getLoadedEffectIds();
    _player.state.allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
  }

  /// Preloads a batch of sound effects in parallel.
  Future<void> preloadEffects(List<AudioEffect> effects) async {
    _player.ensureNotDisposed();
    await Future.wait(effects.map(loadEffect));
  }

  /// Triggers playback of a polyphonic RAM effect voice.
  Future<VoiceId> playEffect(
    String id, {
    DspRouting dspRouting = DspRouting.inherit,
    EffectConfig config = const EffectConfig(),
    double? volume,
    double? pitch,
    double? pitchJitter,
    double? volumeJitter,
    SpatialEmitter? spatial,
    bool? looping,
  }) async {
    _player.ensureNotDisposed();
    final effectiveConfig = config.copyWith(
      volume: volume,
      pitch: pitch,
      pitchJitter: pitchJitter,
      volumeJitter: volumeJitter,
      spatial: spatial,
      looping: looping,
    );

    final voiceId = _rust.playEffect(
      id: id,
      dspRouting: dspRouting.value,
      config: rust_types.RustEffectConfig(
        volume: effectiveConfig.volume,
        balance: effectiveConfig.balance,
        pitch: effectiveConfig.pitch,
        rate: effectiveConfig.rate,
        looping: effectiveConfig.looping,
        priority: effectiveConfig.priority,
        pitchJitter: effectiveConfig.pitchJitter,
        volumeJitter: effectiveConfig.volumeJitter,
        spatial: effectiveConfig.spatial != null
            ? _toRustEmitter(effectiveConfig.spatial!)
            : null,
      ),
    );
    return voiceId;
  }

  /// Stops an active effect voice with a linear fade-out.
  Future<void> stopEffect(
    VoiceId voiceId, {
    Duration fadeOut = const Duration(milliseconds: 5),
  }) async {
    _player.ensureNotDisposed();
    _rust.stopEffect(
      voiceId: voiceId,
      fadeOutMs: BigInt.from(fadeOut.inMilliseconds),
    );
  }

  /// Stops all currently rendering polyphonic effect voices.
  Future<void> stopAllEffects({
    Duration fadeOut = const Duration(milliseconds: 5),
  }) async {
    _player.ensureNotDisposed();
    _rust.stopAllEffects(fadeOutMs: BigInt.from(fadeOut.inMilliseconds));
  }

  /// Modulates the volume of an active polyphonic voice in real time.
  Future<void> setEffectVolume(VoiceId voiceId, double volume) async {
    _player.ensureNotDisposed();
    _rust.setEffectVolume(voiceId: voiceId, volume: volume.toDouble());
  }

  /// Modulates the pitch of an active polyphonic voice in real time.
  Future<void> setEffectPitch(VoiceId voiceId, double pitch) async {
    _player.ensureNotDisposed();
    _rust.setEffectPitch(voiceId: voiceId, pitch: pitch.toDouble());
  }

  /// Modulates the stereo balance of an active polyphonic voice.
  Future<void> setEffectBalance(VoiceId voiceId, double balance) async {
    _player.ensureNotDisposed();
    _rust.setEffectBalance(voiceId: voiceId, balance: balance.toDouble());
  }

  /// Updates the 3D position and velocity of an active polyphonic voice.
  Future<void> setEffectEmitter(
    VoiceId voiceId,
    SpatialEmitter emitter,
  ) async {
    _player.ensureNotDisposed();
    _rust.setEffectEmitter(
      voiceId: voiceId,
      emitter: _toRustEmitter(emitter),
    );
  }

  /// Updates the 3D spatial position, orientation, and velocity of the listener.
  Future<void> setListener(SpatialListener listener) async {
    _player.ensureNotDisposed();
    _rust.setListener(listener: _toRustListener(listener));
  }

  /// Calibrates the physics of the 3D Doppler effect.
  Future<void> setDopplerParameters({
    double factor = 1.0,
    double speedOfSound = 343.3,
  }) async {
    _player.ensureNotDisposed();
    _rust.setDopplerParameters(
      factor: factor,
      speedOfSound: speedOfSound,
    );
  }

  // =========================================================================
  // Multi-Destination Output Matrix & Recording
  // =========================================================================

  /// Configures the active output destinations for this player instance.
  Future<void> configureOutputs(Iterable<AudioOutput> outputs) async {
    _player.ensureNotDisposed();
    final rustOutputs = outputs.map((out) {
      switch (out) {
        case SpeakerAudioOutput(:final exclusiveMode):
          return rust_types.RustAudioOutput.speaker(
            exclusiveMode: exclusiveMode,
          );
        case DeviceAudioOutput(:final deviceId, :final exclusiveMode):
          return rust_types.RustAudioOutput.device(
            deviceId: deviceId,
            exclusiveMode: exclusiveMode,
          );
        case CueAudioOutput(:final deviceId, :final source):
          return rust_types.RustAudioOutput.cue(
            deviceId: deviceId,
            source: source.value,
          );
        case FileAudioOutput(:final path, :final format):
          return rust_types.RustAudioOutput.file(
            path: path,
            format: format.index,
          );
      }
    }).toList();
    await _rust.configureOutputs(outputs: rustOutputs);
    if (_player.isDisposed) return;
    _player.activeOutputsSet
      ..clear()
      ..addAll(outputs);
    _player.state.outputs = Set.of(outputs);
    if (!_player.stream.outputsController.isClosed) {
      _player.stream.outputsController.add(_player.state.outputs);
    }
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets the active outputs for this player instance, replacing any existing ones.
  Future<void> setOutputs(Set<AudioOutput> outputs) =>
      configureOutputs(outputs);

  /// Adds an output destination to this player's active outputs.
  Future<void> addOutput(AudioOutput output) async {
    _player.ensureNotDisposed();
    switch (output) {
      case SpeakerAudioOutput(:final exclusiveMode):
        _rust.addOutput(
          output: rust_types.RustAudioOutput.speaker(
            exclusiveMode: exclusiveMode,
          ),
        );
      case DeviceAudioOutput(:final deviceId, :final exclusiveMode):
        _rust.addOutput(
          output: rust_types.RustAudioOutput.device(
            deviceId: deviceId,
            exclusiveMode: exclusiveMode,
          ),
        );
      case CueAudioOutput(:final deviceId, :final source):
        _rust.addOutput(
          output: rust_types.RustAudioOutput.cue(
            deviceId: deviceId,
            source: source.value,
          ),
        );
      case FileAudioOutput(:final path, :final format):
        await startRecording(path, format: format);
    }
    _player.activeOutputsSet.add(output);
    _player.state.outputs = Set.of(_player.activeOutputsSet);
    _player.stream.outputsController.add(_player.state.outputs);
    await Future<void>.delayed(Duration.zero);
  }

  /// Removes an output destination from this player's active outputs.
  Future<void> removeOutput(AudioOutput output) async {
    _player.ensureNotDisposed();
    switch (output) {
      case SpeakerAudioOutput(:final exclusiveMode):
        _rust.removeOutput(
          output: rust_types.RustAudioOutput.speaker(
            exclusiveMode: exclusiveMode,
          ),
        );
      case DeviceAudioOutput(:final deviceId, :final exclusiveMode):
        _rust.removeOutput(
          output: rust_types.RustAudioOutput.device(
            deviceId: deviceId,
            exclusiveMode: exclusiveMode,
          ),
        );
      case CueAudioOutput(:final deviceId, :final source):
        _rust.removeOutput(
          output: rust_types.RustAudioOutput.cue(
            deviceId: deviceId,
            source: source.value,
          ),
        );
      case FileAudioOutput():
        await stopRecording();
    }
    _player.activeOutputsSet.remove(output);
    _player.state.outputs = Set.of(_player.activeOutputsSet);
    _player.stream.outputsController.add(_player.state.outputs);
    await Future<void>.delayed(Duration.zero);
  }

  /// Routes signal to headphone CUE pre-listening output.
  Future<void> setCueSource(CueSource source) async {
    _player.ensureNotDisposed();
    _rust.setCueSource(source: source.value);
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets headphone CUE pre-listening volume multiplier.
  Future<void> setCueVolume(double volume) async {
    _player.ensureNotDisposed();
    _rust.setCueVolume(volume: volume.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Starts live lock-free recording of the master bus to disk.
  Future<void> startRecording(
    String path, {
    dynamic format = AudioFileFormat.wav,
  }) async {
    _player.ensureNotDisposed();
    int formatIndex = 0;
    if (format is AudioFileFormat) {
      formatIndex = format.index;
    }
    await _rust.startRecording(path: path, format: formatIndex);
    await Future<void>.delayed(Duration.zero);
  }

  /// Stops live disk recording and returns an immutable [RecordingResult].
  Future<RecordingResult> stopRecording() async {
    _player.ensureNotDisposed();
    final res = await _rust.stopRecording();
    await Future<void>.delayed(Duration.zero);
    return RecordingResult(
      path: res.path,
      duration: Duration(milliseconds: res.durationMs.toInt()),
      bytesWritten: res.bytesWritten.toInt(),
      sampleCount: res.sampleCount.toInt(),
    );
  }

  // =========================================================================
  // Input Routing Matrix & Microphone Capture
  // =========================================================================

  /// Adds an audio input source to this player instance.
  Future<void> addInput(AudioInput input) async {
    _player.ensureNotDisposed();
    if (input is MicrophoneAudioInput) {
      await enableMicrophone(
        deviceId: input.deviceId,
        volume: input.volume,
        ducking: input.ducking,
        monitorDirect: input.monitorDirect,
        monitorVolume: input.monitorVolume,
      );
    }
  }

  /// Removes an audio input source from this player instance.
  Future<void> removeInput(AudioInput input) async {
    _player.ensureNotDisposed();
    if (input is MicrophoneAudioInput) {
      await disableMicrophone();
    }
  }

  /// Sets the active inputs for this player instance, replacing any existing ones.
  Future<void> setInputs(Set<AudioInput> inputs) async {
    _player.ensureNotDisposed();
    await clearInputs();
    for (final inp in inputs) {
      await addInput(inp);
    }
  }

  /// Clears all active audio input sources from this player instance.
  Future<void> clearInputs() async {
    _player.ensureNotDisposed();
    await disableMicrophone();
  }

  /// Enables hardware microphone capture with Auto-Ducking and direct monitoring.
  Future<void> enableMicrophone({
    String? deviceId,
    double volume = 1.0,
    DuckingConfig? ducking,
    bool monitorDirect = false,
    double monitorVolume = 1.0,
  }) async {
    _player.ensureNotDisposed();
    final d = ducking ?? const DuckingConfig();
    await _rust.enableMicrophone(
      deviceId: deviceId,
      volume: volume.toDouble(),
      ducking: d.toRust(),
      monitorDirect: monitorDirect,
      monitorVolume: monitorVolume.toDouble(),
    );
    final input = AudioInput.microphone(
      deviceId: deviceId,
      volume: volume,
      ducking: ducking,
      monitorDirect: monitorDirect,
      monitorVolume: monitorVolume,
    );
    final next = Set<AudioInput>.of(_player.state.inputs)..add(input);
    _player.state.inputs = next;
    _player.stream.inputsController.add(next);
    await Future<void>.delayed(Duration.zero);
  }

  /// Disables and frees hardware microphone capture.
  Future<void> disableMicrophone() async {
    _player.ensureNotDisposed();
    _rust.disableMicrophone();
    final next = Set<AudioInput>.of(_player.state.inputs)
      ..removeWhere((i) => i is MicrophoneAudioInput);
    _player.state.inputs = next;
    _player.stream.inputsController.add(next);
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets microphone input capture volume.
  Future<void> setMicrophoneVolume(double volume) async {
    _player.ensureNotDisposed();
    _rust.setMicrophoneVolume(volume: volume.toDouble());
    await Future<void>.delayed(Duration.zero);
  }

  /// Configures microphone Auto-Ducking sidechain compressor.
  Future<void> setDucking(DuckingConfig config) async {
    _player.ensureNotDisposed();
    _rust.setDucking(config: config.toRust());
    await Future<void>.delayed(Duration.zero);
  }

  /// Toggles low-latency direct monitoring of voice into headphones.
  Future<void> setDirectMonitoring({
    required bool enabled,
    double volume = 1.0,
  }) async {
    _player.ensureNotDisposed();
    _rust.setDirectMonitoring(
      enabled: enabled,
      volume: volume.toDouble(),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  // =========================================================================
  // Spatial Conversion Helpers
  // =========================================================================

  static rust_types.RustSpatialEmitter _toRustEmitter(SpatialEmitter e) =>
      rust_types.RustSpatialEmitter(
        position: rust_types.RustVector3(
          x: e.position.x,
          y: e.position.y,
          z: e.position.z,
        ),
        velocity: rust_types.RustVector3(
          x: e.velocity.x,
          y: e.velocity.y,
          z: e.velocity.z,
        ),
        direction: e.direction != null
            ? rust_types.RustVector3(
                x: e.direction!.x,
                y: e.direction!.y,
                z: e.direction!.z,
              )
            : null,
        minDistance: e.minDistance,
        maxDistance: e.maxDistance,
        rolloffFactor: e.rolloffFactor,
        dopplerFactor: e.dopplerFactor,
        innerAngleRad: e.innerAngleRad,
        outerAngleRad: e.outerAngleRad,
        outerGain: e.outerGain,
        distanceModel: rust_types.RustDistanceModel.inverse,
      );

  static rust_types.RustSpatialListener _toRustListener(SpatialListener l) =>
      rust_types.RustSpatialListener(
        position: rust_types.RustVector3(
          x: l.position.x,
          y: l.position.y,
          z: l.position.z,
        ),
        velocity: rust_types.RustVector3(
          x: l.velocity.x,
          y: l.velocity.y,
          z: l.velocity.z,
        ),
        forward: rust_types.RustVector3(
          x: l.forward.x,
          y: l.forward.y,
          z: l.forward.z,
        ),
        up: rust_types.RustVector3(x: l.up.x, y: l.up.y, z: l.up.z),
      );
}
