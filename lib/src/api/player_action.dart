import 'dart:async';
import 'dart:typed_data' hide Int64List;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show Int64List;

import '../equalizer.dart';
import '../reverb.dart';
import '../rust/api/player.dart' as rust;
import '../rust/api/types.dart' as rust_types;
import 'audio_source.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'logger.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'player_models.dart';
import 'recording.dart' show DuckingConfig;
import 'silence_skip_config.dart';
import 'spatial.dart';

/// Action interface executing asynchronous playback, queue, effects, and DSP controls.
///
/// In strict accordance with the stream-driven architecture, actions dispatch commands
/// to Rust via FFI and rely on the native Rust event pipeline as the authoritative source
/// for state transitions and telemetry.
class PlayerAction<T> {
  final MiniaudioPlayer<T> _player;
  final rust.RustMiniaudioPlayer _rust;

  /// Creates a [PlayerAction] command dispatcher for [_player] and [_rust].
  PlayerAction(this._player, this._rust);

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
    if (s.customProvider != null) {
      final provider = s.customProvider!;
      final streamId = provider.streamId != 0 ? provider.streamId : id;
      final url = provider.totalBytes != null
          ? 'custom://$streamId?size=${provider.totalBytes}'
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

  (AudioSource<T> retained, rust_types.RustAudioSource rustSource)
      _prepareSource(
    AudioSource<T> s, [
    Uint8List? customInitBytes,
  ]) {
    final uniqueId = s.id ?? _player.nextSourceId++;
    s.attachEngineId(uniqueId);

    final rustSource = _toRustSource(s, uniqueId, customInitBytes);

    if (s.isMemory) {
      // Transfer byte payload ownership exclusively to Rust and release Dart heap buffer.
      s.clearBytes();
    } else if (s.customProvider != null) {
      final provider = s.customProvider!;
      _player.customProviders[uniqueId] = provider;
      if (provider.streamId != 0) {
        _player.customProviders[provider.streamId] = provider;
      }
    }

    _player.sourceRegistry[uniqueId] = s;
    return (s, rustSource);
  }

  // =========================================================================
  // Master Transport Controls
  // =========================================================================

  /// Starts, resumes, skips to a target track, or seeks within the playlist queue.
  ///
  /// ### Resolution Hierarchy
  /// - If [id] is non-null: [id] takes precedence over [position].
  /// - If [id] is `null` and [position] is non-null: [position] is used.
  /// - If both are `null`: targets the current item (or index `0` on first play) and starts/resumes playback.
  ///
  /// ### Behavior
  /// - **First playback (`state.currentIndex == null`)**:
  ///   - When `shuffled == true` and a target ([id] or [position]) is provided, that track is pinned
  ///     to index `0` of the active queue and all remaining tracks from the original order are shuffled
  ///     behind it. Playback starts on index `0`.
  ///   - When `shuffled == true` and no target is provided, the entire queue is shuffled and playback
  ///     starts on index `0`.
  ///   - When `shuffled == false` (or omitted), playback begins at the resolved target (or `0`).
  /// - **Active queue navigation (`state.currentIndex != null`)**:
  ///   - When both [id] and [position] are `null`, resumes playback of the current track (and seeks if
  ///     [seek] is provided). If [shuffled] is provided, updates shuffle mode.
  ///   - When [id] or [position] is provided, [position] refers to the active `state.queue` (without
  ///     re-shuffling) and transitions to the target track (using a manual crossfade if currently playing).
  Future<void> play({
    int? id,
    int? position,
    bool? shuffled,
    Duration? seek,
  }) =>
      _serialize(() async {
        _player.ensureNotDisposed();
        if (position != null && position < 0) {
          throw RangeError.value(
            position,
            'position',
            'Queue position must be non-negative',
          );
        }
        final seekMs = seek != null
            ? (seek < Duration.zero ? 0 : seek.inMilliseconds)
            : null;
        MapLogger.info(
          'play(id: $id, position: $position, shuffled: $shuffled, seekMs: $seekMs) requested',
        );
        try {
          await _rust.play(
            id: id,
            position: position != null ? BigInt.from(position) : null,
            shuffled: shuffled,
            seekMs: seekMs,
          );
        } catch (e) {
          if (e is MiniaudioPlayerException) rethrow;
          throw MiniaudioPlayerException.fromRustError(e);
        }
        await applyCurrentTrackReplayGain();
        _player.checkInfiniteMix();
        await Future<void>.delayed(const Duration(milliseconds: 10));
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
        final targetPosition =
            position < Duration.zero ? Duration.zero : position;
        MapLogger.info('seek() requested -> ${targetPosition.inMilliseconds}ms');
        _rust.seek(positionMs: targetPosition.inMilliseconds);
        await Future<void>.delayed(Duration.zero);
      });

  // =========================================================================
  // Playlist Queue Management
  // =========================================================================

  /// Sets or replaces the music playlist queue without starting playback.
  ///
  /// Resets `state.currentIndex` to `null` until [play] is invoked.
  Future<void> setQueue(List<AudioSource<T>> sources) {
    return _serialize(() async {
      _player.ensureNotDisposed();
      MapLogger.info('setQueue() requested with ${sources.length} items');

      _player.sourceRegistry.clear();
      _player.customProviders.clear();

      final normalized = <AudioSource<T>>[];
      final rustSources = <rust_types.RustAudioSource>[];
      for (var i = 0; i < sources.length; i++) {
        final s = sources[i];
        Uint8List? initBytes;
        if (s.customProvider != null) {
          initBytes = await s.customProvider!.readInitialBytes();
        }
        final (retained, rustSource) = _prepareSource(s, initBytes);
        normalized.add(retained);
        rustSources.add(rustSource);
      }

      _player.state.queue = List.unmodifiable(normalized);
      _player.state.currentIndex = null;

      try {
        await _rust.setQueue(queue: rustSources);
      } catch (e) {
        if (e is MiniaudioPlayerException) rethrow;
        throw MiniaudioPlayerException.fromRustError(e);
      }

      await applyCurrentTrackReplayGain();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }

  /// Appends tracks to the end of the current playlist queue.
  Future<void> append(List<AudioSource<T>> sources) async {
    _player.ensureNotDisposed();
    if (sources.isEmpty) return;

    final normalized = <AudioSource<T>>[];
    final rustSources = <rust_types.RustAudioSource>[];
    for (final s in sources) {
      Uint8List? initBytes;
      if (s.customProvider != null) {
        initBytes = await s.customProvider!.readInitialBytes();
      }
      final (retained, rustSource) = _prepareSource(s, initBytes);
      normalized.add(retained);
      rustSources.add(rustSource);
    }
    _player.state.queue = List.unmodifiable([
      ..._player.state.queue,
      ...normalized,
    ]);
    _rust.append(sources: rustSources);
    await Future<void>.delayed(Duration.zero);
  }

  /// Inserts a track immediately after the active playing track.
  Future<void> insertNext(AudioSource<T> source) async {
    _player.ensureNotDisposed();
    Uint8List? initBytes;
    if (source.customProvider != null) {
      initBytes = await source.customProvider!.readInitialBytes();
    }
    final (retained, rustSource) = _prepareSource(source, initBytes);
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    final curIdx = _player.state.currentIndex;
    final insertIdx = (curIdx != null && curIdx >= 0 && curIdx < currentQueue.length)
        ? curIdx + 1
        : currentQueue.length;
    currentQueue.insert(insertIdx, retained);
    _player.state.queue = List.unmodifiable(currentQueue);
    _rust.insertNext(source: rustSource);
    await Future<void>.delayed(Duration.zero);
  }

  /// Removes a track at [index] from the playlist queue.
  Future<void> removeAt(int index) async {
    _player.ensureNotDisposed();
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    if (index >= 0 && index < currentQueue.length) {
      final removed = currentQueue.removeAt(index);
      if (removed.id != null) {
        _player.sourceRegistry.remove(removed.id);
        _player.customProviders.remove(removed.id);
      }
      _player.state.queue = List.unmodifiable(currentQueue);
      _rust.removeAt(index: BigInt.from(index));
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Reorders a track from [oldIndex] to [newIndex] within the queue.
  Future<void> reorder(int oldIndex, int newIndex) async {
    _player.ensureNotDisposed();
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    if (oldIndex >= 0 &&
        oldIndex < currentQueue.length &&
        newIndex >= 0 &&
        newIndex < currentQueue.length) {
      final item = currentQueue.removeAt(oldIndex);
      currentQueue.insert(newIndex, item);
      _player.state.queue = List.unmodifiable(currentQueue);
      final ids = currentQueue.map((s) => s.id ?? 0).toList();
      _rust.reorderByIds(ids: Int64List.fromList(ids));
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Reorders the playlist queue using an ordered list of unique track [ids].
  Future<void> reorderByIds(List<int> ids) async {
    _player.ensureNotDisposed();
    final reordered = <AudioSource<T>>[];
    for (final id in ids) {
      final s = _player.sourceRegistry[id];
      if (s != null) reordered.add(s);
    }
    if (reordered.length == _player.state.queue.length) {
      _player.state.queue = List.unmodifiable(reordered);
    }
    _rust.reorderByIds(ids: Int64List.fromList(ids));
    await Future<void>.delayed(Duration.zero);
  }

  /// Clears the playlist queue. If [keepCurrent] is true, retains the playing track.
  Future<void> clearQueue({bool keepCurrent = false}) async {
    _player.ensureNotDisposed();
    final curIdx = _player.state.currentIndex;
    if (keepCurrent &&
        _player.state.queue.isNotEmpty &&
        curIdx != null &&
        curIdx >= 0 &&
        curIdx < _player.state.queue.length) {
      final cur = _player.state.queue[curIdx];
      _player.state.queue = List.unmodifiable([cur]);
      _player.state.currentIndex = 0;
      final curId = cur.id;
      _player.sourceRegistry.removeWhere((id, _) => id != curId);
      _player.customProviders.removeWhere((id, _) => id != curId);
    } else {
      _player.state.queue = const [];
      _player.state.currentIndex = null;
      _player.sourceRegistry.clear();
      _player.customProviders.clear();
    }
    _rust.clearQueue(keepCurrent: keepCurrent);
    await Future<void>.delayed(Duration.zero);
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

  /// Configures infinite queue replenishment when playback approaches the end of the queue.
  Future<void> setInfiniteMix(
    bool enabled, {
    InfiniteMixProvider<T>? provider,
    int remainingTracksThreshold = 2,
  }) async {
    _player.ensureNotDisposed();
    _player.state.infiniteMixEnabled = enabled;
    _player.infiniteMixThreshold = remainingTracksThreshold;
    if (provider != null) {
      _player.infiniteMixProvider = provider;
    }
    if (!_player.stream.infiniteMixEnabledController.isClosed) {
      _player.stream.infiniteMixEnabledController.add(enabled);
    }
    _player.checkInfiniteMix();
  }

  /// Configures crossfade duration and curve between queue tracks.
  Future<void> setCrossfade(CrossfadeConfig config) async {
    _player.ensureNotDisposed();
    _rust.setCrossfade(
      config: rust_types.RustCrossfadeConfig(
        autoDurationMs: BigInt.from(
          config.autoDuration.inMilliseconds < 0
              ? 0
              : config.autoDuration.inMilliseconds,
        ),
        manualDurationMs: BigInt.from(
          config.manualDuration.inMilliseconds < 0
              ? 0
              : config.manualDuration.inMilliseconds,
        ),
        curve: config.curve == CrossfadeCurve.linear ? 1 : 0,
      ),
    );
  }

  // =========================================================================
  // Audio Modulation & DSP Controls
  // =========================================================================

  /// Modulates master audio volume (`>= 0.0`, unconstrained upper limit).
  Future<void> setVolume(double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(volume, 'volume', 'Volume must be >= 0.0');
    }
    MapLogger.info('setVolume() -> $volume');
    _rust.setVolume(volume: volume.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Modulates playback rate multiplier preserving pitch (`> 0.0`).
  Future<void> setRate(double rate) async {
    _player.ensureNotDisposed();
    if (rate.isNaN || rate.isInfinite || rate <= 0.0) {
      throw ArgumentError.value(rate, 'rate', 'Rate must be > 0.0');
    }
    _rust.setRate(rate: rate.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Modulates musical pitch multiplier (`> 0.0`).
  Future<void> setPitch(double pitch) async {
    _player.ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite || pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be > 0.0');
    }
    _rust.setPitch(pitch: pitch.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets stereo balance / pan (`-1.0` left to `+1.0` right).
  Future<void> setBalance(double balance) async {
    _player.ensureNotDisposed();
    _rust.setBalance(balance: balance.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Toggles monophonic downmixing of stereo channels.
  Future<void> setMono(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setMono(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Enables or disables real-time 10-band FFT spectrum visualizer calculation in the native engine.
  ///
  /// For events to be emitted across `PlayerStream.visualizer`, this must be set to `true`.
  /// Defaults to `false`.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player.ensureNotDisposed();
    _rust.setVisualizerEnabled(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Enables or disables raw metadata dispatch from the native audio engine.
  ///
  /// When enabled, raw metadata bytes (e.g. ID3, Vorbis, ICY stream metadata) are emitted
  /// across `PlayerStream.metaBytes` and stored in `PlayerState.metaBytes`.
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
        'Expected bool or SilenceSkipConfig, got $configOrEnabled',
      );
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
    return _serialize(() async {
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
    });
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
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets binaural crossfeed mode.
  Future<void> setCrossfeed(CrossfeedMode mode) async {
    _player.ensureNotDisposed();
    _rust.setCrossfeed(mode: mode.index);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures stereo widener spatializer.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.0,
  }) async {
    _player.ensureNotDisposed();
    _rust.setSpatializer(enabled: enabled, width: width.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
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

  /// Applies ReplayGain settings for the currently active track (or initial queued track).
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
      final curItem = _player.state.currentItem ??
          (_player.state.queue.isNotEmpty ? _player.state.queue.first : null);
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

  /// Updates playback buffer period size.
  Future<void> setBufferSize(int size) async {
    _player.ensureNotDisposed();
    if (size < 0) {
      throw ArgumentError.value(
        size,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    _rust.setBufferSize(bufferSizeFrames: size);
    await Future<void>.delayed(Duration.zero);
  }

  // =========================================================================
  // Autonomous Memory-Budgeted Sound Effects Subsystem
  // =========================================================================

  /// Registers or replaces the catalog of sound effects in the native audio engine.
  ///
  /// Memory-backed effects (`AudioSource(Uint8List)`) are decoded and pinned in RAM
  /// (immune to eviction), while Dart immediately releases its local byte references.
  /// File and network effects are decoded into RAM within the configured memory budget
  /// and managed autonomously by Rust's multi-factor eviction scorer.
  Future<void> setEffects(List<AudioEffect> effects) async {
    _player.ensureNotDisposed();
    final rustEffects = <rust_types.RustAudioEffect>[];
    for (final effect in effects) {
      final rustSource = _toRustSource(effect.source, 0);
      if (effect.source.isMemory) {
        effect.source.clearBytes();
      }
      rustEffects.add(
        rust_types.RustAudioEffect(
          id: effect.id,
          source: rustSource,
          maxPolyphony: effect.maxPolyphony,
          pinned: effect.pinned,
        ),
      );
    }
    await _rust.setEffects(effects: rustEffects);
    _player.state.loadedEffectIds =
        List.unmodifiable(_rust.getLoadedEffectIds());
    _player.state.allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Triggers playback of a polyphonic sound effect and returns a live [Voice] handle.
  ///
  /// If the effect is not currently decoded in RAM, Rust decodes it on demand and
  /// reactively enforces the configured RAM budget using the multi-factor retention score.
  Future<Voice> playEffect(
    String id, {
    DspRouting dspRouting = DspRouting.inherit,
    EffectConfig config = const EffectConfig(),
    double? volume,
    double? pitch,
    double? balance,
    double? pitchJitter,
    double? volumeJitter,
    SpatialEmitter? emitter,
    SpatialEmitter? spatial,
    bool? looping,
    int? priority,
  }) async {
    _player.ensureNotDisposed();
    final effectiveConfig = config.copyWith(
      volume: volume,
      pitch: pitch,
      balance: balance,
      pitchJitter: pitchJitter,
      volumeJitter: volumeJitter,
      spatial: emitter ?? spatial,
      looping: looping,
      priority: priority,
    );
    if (effectiveConfig.volume.isNaN ||
        effectiveConfig.volume.isInfinite ||
        effectiveConfig.volume < 0.0) {
      throw ArgumentError.value(
        effectiveConfig.volume,
        'volume',
        'Effect volume must be >= 0.0',
      );
    }
    if (effectiveConfig.pitch.isNaN ||
        effectiveConfig.pitch.isInfinite ||
        effectiveConfig.pitch <= 0.0) {
      throw ArgumentError.value(
        effectiveConfig.pitch,
        'pitch',
        'Effect pitch must be > 0.0',
      );
    }
    if (effectiveConfig.rate.isNaN ||
        effectiveConfig.rate.isInfinite ||
        effectiveConfig.rate <= 0.0) {
      throw ArgumentError.value(
        effectiveConfig.rate,
        'rate',
        'Effect rate must be > 0.0',
      );
    }

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
    _player.state.loadedEffectIds =
        List.unmodifiable(_rust.getLoadedEffectIds());
    _player.state.allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
    return Voice(voiceId, this);
  }

  /// Stops an active polyphonic voice with a linear fade-out.
  Future<void> stopVoice(
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

  /// Modulates the volume of an active polyphonic voice in real time (`>= 0.0`).
  Future<void> setVoiceVolume(VoiceId voiceId, double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(volume, 'volume', 'Voice volume must be >= 0.0');
    }
    _rust.setEffectVolume(voiceId: voiceId, volume: volume.toDouble());
  }

  /// Modulates the pitch of an active polyphonic voice in real time (`> 0.0`).
  Future<void> setVoicePitch(VoiceId voiceId, double pitch) async {
    _player.ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite || pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Voice pitch must be > 0.0');
    }
    _rust.setEffectPitch(voiceId: voiceId, pitch: pitch.toDouble());
  }

  /// Modulates the stereo balance of an active polyphonic voice (`-1.0` to `1.0`).
  Future<void> setVoiceBalance(VoiceId voiceId, double balance) async {
    _player.ensureNotDisposed();
    _rust.setEffectBalance(voiceId: voiceId, balance: balance.toDouble());
  }

  /// Updates the 3D position and velocity of an active polyphonic voice.
  Future<void> setVoiceEmitter(
    VoiceId voiceId,
    SpatialEmitter emitter,
  ) async {
    _player.ensureNotDisposed();
    _rust.setEffectEmitter(
      voiceId: voiceId,
      emitter: _toRustEmitter(emitter),
    );
  }

  /// Updates the 3D spatial position, orientation, and velocity of the global listener.
  Future<void> setListener(SpatialListener listener) async {
    _player.ensureNotDisposed();
    _rust.setListener(listener: _toRustListener(listener));
  }

  /// Calibrates the global physics of the 3D Doppler effect.
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

  /// Sets the active outputs for this player instance, replacing any existing ones.
  Future<void> setOutputs(Set<AudioOutput> outputs) async {
    _player.ensureNotDisposed();
    final rustOutputs = outputs.map((out) {
      return rust_types.RustAudioOutput(
        deviceId: out.deviceId,
        exclusiveMode: out.exclusiveMode,
        source: out.source.value,
      );
    }).toList();
    _rust.setOutputs(outputs: rustOutputs);
  }

  /// Adds an output destination to this player's active outputs.
  Future<void> addOutput(AudioOutput output) async {
    _player.ensureNotDisposed();
    _rust.addOutput(
      output: rust_types.RustAudioOutput(
        deviceId: output.deviceId,
        exclusiveMode: output.exclusiveMode,
        source: output.source.value,
      ),
    );
  }

  /// Removes an output destination from this player's active outputs.
  Future<void> removeOutput(AudioOutput output) async {
    _player.ensureNotDisposed();
    _rust.removeOutput(
      output: rust_types.RustAudioOutput(
        deviceId: output.deviceId,
        exclusiveMode: output.exclusiveMode,
        source: output.source.value,
      ),
    );
  }

  /// Starts live lock-free recording of rendered audio to disk with a selective source.
  Future<void> startRecording(
    String path, {
    AudioFileFormat format = AudioFileFormat.wav,
    AudioOutputSource source = AudioOutputSource.all,
  }) async {
    _player.ensureNotDisposed();
    await _rust.startRecording(
      path: path,
      format: format.index,
      source: source.value,
    );
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
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Microphone volume must be >= 0.0',
      );
    }
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

  /// Sets microphone input capture volume (`>= 0.0`).
  Future<void> setMicrophoneVolume(double volume) async {
    _player.ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(
        volume,
        'volume',
        'Microphone volume must be >= 0.0',
      );
    }
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
