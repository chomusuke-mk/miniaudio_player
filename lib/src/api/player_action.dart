part of 'miniaudio_player.dart';

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

  rust_types.RustAudioSource _toRustSource(
    AudioSource<dynamic> s,
    int id,
  ) {
    if (s.customProvider != null) {
      final provider = s.customProvider!;
      final streamId = provider.streamId != 0 ? provider.streamId : id;
      final url = provider.totalBytes != null
          ? 'custom://$streamId?size=${provider.totalBytes}'
          : 'custom://$streamId';
      return rust_types.RustAudioSource(
        id: id,
        source: url,
        dataBytes: null,
        replayGainDb: s.replayGainDb,
        replayPeak: s.replayPeak,
      );
    }
    final raw = s.toRustSource(id);
    return rust_types.RustAudioSource(
      id: raw.id,
      source: raw.source,
      headers: raw.headers,
      dataBytes: raw.dataBytes,
      replayGainDb: s.replayGainDb,
      replayPeak: raw.replayPeak,
    );
  }

  (AudioSource<T> retained, rust_types.RustAudioSource rustSource)
      _prepareSource(
    AudioSource<T> s,
  ) {
    final uniqueId = s.id ?? _player._nextSourceId++;
    s._attachEngineId(uniqueId);

    final rustSource = _toRustSource(s, uniqueId);

    if (s.isMemory) {
      // Transfer byte payload ownership exclusively to Rust and release Dart heap buffer.
      s._clearBytes();
    } else if (s.customProvider != null) {
      final provider = s.customProvider!;
      _player._customProviders[uniqueId] = provider;
      if (provider.streamId != 0) {
        _player._customProviders[provider.streamId] = provider;
      }
    }

    _player._sourceRegistry[uniqueId] = s;
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
        _player._ensureNotDisposed();
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
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });

  /// Pauses audio playback at current position.
  Future<void> pause() => _serialize(() async {
        _player._ensureNotDisposed();
        MapLogger.info('pause() requested');
        _rust.pause();
        await Future<void>.delayed(Duration.zero);
      });

  /// Stops playback and rewinds position to zero.
  Future<void> stop() => _serialize(() async {
        _player._ensureNotDisposed();
        MapLogger.info('stop() requested');
        _rust.stop();
        await Future<void>.delayed(Duration.zero);
      });

  /// Seeks to specified position in the currently playing track.
  Future<void> seek(Duration position) => _serialize(() async {
        _player._ensureNotDisposed();
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
      _player._ensureNotDisposed();
      MapLogger.info('setQueue() requested with ${sources.length} items');

      _player._sourceRegistry.clear();
      _player._customProviders.clear();

      final normalized = <AudioSource<T>>[];
      final rustSources = <rust_types.RustAudioSource>[];
      for (var i = 0; i < sources.length; i++) {
        final (retained, rustSource) = _prepareSource(sources[i]);
        normalized.add(retained);
        rustSources.add(rustSource);
      }

      _player.state._queue = List.unmodifiable(normalized);
      _player.state._currentIndex = null;

      try {
        await _rust.setQueue(queue: rustSources);
      } catch (e) {
        if (e is MiniaudioPlayerException) rethrow;
        throw MiniaudioPlayerException.fromRustError(e);
      }

      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }

  /// Appends tracks to the end of the current playlist queue.
  Future<void> append(List<AudioSource<T>> sources) async {
    _player._ensureNotDisposed();
    if (sources.isEmpty) return;

    final normalized = <AudioSource<T>>[];
    final rustSources = <rust_types.RustAudioSource>[];
    for (final s in sources) {
      final (retained, rustSource) = _prepareSource(s);
      normalized.add(retained);
      rustSources.add(rustSource);
    }
    _player.state._queue = List.unmodifiable([
      ..._player.state.queue,
      ...normalized,
    ]);
    _rust.append(sources: rustSources);
    await Future<void>.delayed(Duration.zero);
  }

  /// Inserts a track immediately after the active playing track.
  Future<void> insertNext(AudioSource<T> source) async {
    _player._ensureNotDisposed();
    final (retained, rustSource) = _prepareSource(source);
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    final curIdx = _player.state.currentIndex;
    final insertIdx = (curIdx != null && curIdx >= 0 && curIdx < currentQueue.length)
        ? curIdx + 1
        : currentQueue.length;
    currentQueue.insert(insertIdx, retained);
    _player.state._queue = List.unmodifiable(currentQueue);
    _rust.insertNext(source: rustSource);
    await Future<void>.delayed(Duration.zero);
  }

  /// Removes a track at [index] from the playlist queue.
  Future<void> removeAt(int index) async {
    _player._ensureNotDisposed();
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    if (index >= 0 && index < currentQueue.length) {
      final removed = currentQueue.removeAt(index);
      if (removed.id != null) {
        _player._sourceRegistry.remove(removed.id);
        _player._customProviders.remove(removed.id);
      }
      _player.state._queue = List.unmodifiable(currentQueue);
      _rust.removeAt(index: BigInt.from(index));
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Reorders a track from [oldIndex] to [newIndex] within the queue.
  Future<void> reorder(int oldIndex, int newIndex) async {
    _player._ensureNotDisposed();
    final currentQueue = List<AudioSource<T>>.of(_player.state.queue);
    if (oldIndex >= 0 &&
        oldIndex < currentQueue.length &&
        newIndex >= 0 &&
        newIndex < currentQueue.length) {
      final item = currentQueue.removeAt(oldIndex);
      currentQueue.insert(newIndex, item);
      _player.state._queue = List.unmodifiable(currentQueue);
      final ids = currentQueue.map((s) => s.id ?? 0).toList();
      _rust.reorderByIds(ids: Int64List.fromList(ids));
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Reorders the playlist queue using an ordered list of unique track [ids].
  Future<void> reorderByIds(List<int> ids) async {
    _player._ensureNotDisposed();
    final reordered = <AudioSource<T>>[];
    for (final id in ids) {
      final s = _player._sourceRegistry[id];
      if (s != null) reordered.add(s);
    }
    if (reordered.length == _player.state.queue.length) {
      _player.state._queue = List.unmodifiable(reordered);
    }
    _rust.reorderByIds(ids: Int64List.fromList(ids));
    await Future<void>.delayed(Duration.zero);
  }

  /// Clears the playlist queue. If [keepCurrent] is true, retains the playing track.
  Future<void> clearQueue({bool keepCurrent = false}) async {
    _player._ensureNotDisposed();
    final curIdx = _player.state.currentIndex;
    if (keepCurrent &&
        _player.state.queue.isNotEmpty &&
        curIdx != null &&
        curIdx >= 0 &&
        curIdx < _player.state.queue.length) {
      final cur = _player.state.queue[curIdx];
      _player.state._queue = List.unmodifiable([cur]);
      _player.state._currentIndex = 0;
      final curId = cur.id;
      _player._sourceRegistry.removeWhere((id, _) => id != curId);
      _player._customProviders.removeWhere((id, _) => id != curId);
    } else {
      _player.state._queue = const [];
      _player.state._currentIndex = null;
      _player._sourceRegistry.clear();
      _player._customProviders.clear();
    }
    _rust.clearQueue(keepCurrent: keepCurrent);
    await Future<void>.delayed(Duration.zero);
  }

  /// Advances to the next track in the playlist queue.
  Future<void> next({Duration? crossfadeDuration}) => _serialize(() async {
        _player._ensureNotDisposed();
        await _rust.next(
          crossfadeDurationMs: crossfadeDuration != null
              ? BigInt.from(crossfadeDuration.inMilliseconds)
              : null,
        );
        await Future<void>.delayed(Duration.zero);
      });

  /// Skips back to the previous track, or start of current track if > 3s played.
  Future<void> previous() => _serialize(() async {
        _player._ensureNotDisposed();
        await _rust.previous();
        await Future<void>.delayed(Duration.zero);
      });

  /// Configures playlist repeat mode ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  Future<void> setLoopMode(LoopMode mode) async {
    _player._ensureNotDisposed();
    _rust.setLoopMode(mode: mode.index);
    await Future<void>.delayed(Duration.zero);
  }

  /// Enables or disables non-destructive shuffle on the playlist queue.
  Future<void> setShuffle(bool enabled) async {
    _player._ensureNotDisposed();
    _rust.setShuffle(enabled: enabled);
    await Future<void>.delayed(Duration.zero);
  }

  /// Sets the dynamic queue replenishment provider callback for Infinite Mix.
  ///
  /// Pass `null` to remove the active provider.
  void setInfiniteMixProvider(InfiniteMixProvider<T>? provider) {
    _player._infiniteMixProvider = provider;
  }

  /// Configures infinite queue replenishment when playback approaches the end of the queue.
  Future<void> setInfiniteMix(InfiniteMixConfig config) async {
    _player._ensureNotDisposed();
    _rust.setInfiniteMix(
      config: rust_types.RustInfiniteMixConfig(
        enabled: config.enabled,
        remainingTracksThreshold: config.remainingTracksThreshold,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures crossfade duration and curve between queue tracks.
  Future<void> setCrossfade(CrossfadeConfig config) async {
    _player._ensureNotDisposed();
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
    _player._ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(volume, 'volume', 'Volume must be >= 0.0');
    }
    MapLogger.info('setVolume() -> $volume');
    _rust.setVolume(volume: volume.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Modulates playback rate multiplier preserving pitch (`> 0.0`).
  Future<void> setRate(double rate) async {
    _player._ensureNotDisposed();
    if (rate.isNaN || rate.isInfinite || rate <= 0.0) {
      throw ArgumentError.value(rate, 'rate', 'Rate must be > 0.0');
    }
    _rust.setRate(rate: rate.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Modulates musical pitch multiplier (`> 0.0`).
  Future<void> setPitch(double pitch) async {
    _player._ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite || pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Pitch must be > 0.0');
    }
    _rust.setPitch(pitch: pitch.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets stereo balance / pan (`-1.0` left to `+1.0` right).
  Future<void> setBalance(double balance) async {
    _player._ensureNotDisposed();
    _rust.setBalance(balance: balance.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Toggles monophonic downmixing of stereo channels.
  Future<void> setMono(bool enabled) async {
    _player._ensureNotDisposed();
    _rust.setMono(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Applies 10-band ISO peaking equalizer configuration.
  Future<void> setEqualizer(Equalizer equalizer) async {
    _player._ensureNotDisposed();
    _rust.setEqualizer(
      params: rust_types.RustEqualizerParams(
        gains: Float32List.fromList(equalizer.toList()),
        enabled: equalizer.enabled,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures algorithmic studio reverberation.
  Future<void> setReverb(Reverb reverb) async {
    _player._ensureNotDisposed();
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
    _player._ensureNotDisposed();
    _rust.setLimiter(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Enables or disables real-time 10-band FFT spectrum visualizer calculation in the native engine.
  ///
  /// For events to be emitted across `PlayerStream.visualizer`, this must be set to `true`.
  /// Defaults to `false`.
  Future<void> setVisualizerEnabled(bool enabled) async {
    _player._ensureNotDisposed();
    _rust.setVisualizerEnabled(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Enables or disables metadata dispatch from the native audio engine.
  ///
  /// When enabled, [AudioMetadata] events are emitted across `PlayerStream.metadata`
  /// and stored in `PlayerState.metadata`.
  ///
  /// Defaults to `false` to avoid saturating the event bus.
  Future<void> setMetadataEnabled(bool enabled) async {
    _player._ensureNotDisposed();
    _rust.setMetadataEnabled(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures intelligent silence detection and skipping.
  Future<void> setSilenceConfig(SilenceSkipConfig config) async {
    _player._ensureNotDisposed();
    _rust.setSilenceConfig(
      config: rust_types.RustSilenceConfig(
        thresholdDb: config.thresholdDb,
        minSilenceDurationMs: config.minSilenceDuration.inMilliseconds,
        paddingMs: config.padding.inMilliseconds,
        enabled: config.enabled,
        mode: config.mode.value,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets, updates, or clears ReplayGain normalization settings for a queue item or current track.
  ///
  /// Targets the item with [id] or at [position]. If neither is given, targets the currently playing track.
  /// If [config] is `null`, any track-specific ReplayGain configuration is removed.
  Future<void> setReplayGain(
    ReplayGainConfig? config, {
    int? id,
    int? position,
  }) async {
    _player._ensureNotDisposed();
    return _serialize(() async {
      _rust.setReplayGain(
        config: config != null
            ? rust_types.RustReplayGainConfig(
                gainDb: config.gainDb,
                peak: config.peak,
              )
            : null,
        id: id,
        position: position != null ? BigInt.from(position) : null,
      );

      // Synchronize ReplayGain metadata on the targeted AudioSource
      AudioSource<dynamic>? target;
      if (id != null) {
        target = _player._sourceRegistry[id];
        if (target == null) {
          for (final item in _player.state.queue) {
            if (item.id == id) {
              target = item;
              break;
            }
          }
        }
      } else if (position != null) {
        if (position >= 0 && position < _player.state.queue.length) {
          target = _player.state.queue[position];
        }
      } else {
        target = _player.state.currentItem;
      }

      if (target != null) {
        target._replayGainDb = config?.gainDb;
        target._replayPeak = config?.peak;
      }

      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }

  /// Sets preamplifier gain in decibels.
  Future<void> setPreamp(double preampDb) async {
    _player._ensureNotDisposed();
    _rust.setPreamp(preampDb: preampDb.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures Bauer stereophonic-to-binaural (BS2B) crossfeed filtering.
  Future<void> setCrossfeed(Crossfeed crossfeed) async {
    _player._ensureNotDisposed();
    _rust.setCrossfeed(
      config: rust_types.RustCrossfeedConfig(
        enabled: crossfeed.enabled,
        cutoffHz: crossfeed.cutoffHz,
        feedDb: crossfeed.feedDb,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures stereo widener spatializer.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.0,
  }) async {
    _player._ensureNotDisposed();
    _rust.setSpatializer(enabled: enabled, width: width.toDouble());
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets default ReplayGain fallback adjustment in dB and peak.
  Future<void> setDefaultReplayGain(double gainDb, {double peak = 1.0}) async {
    _player._ensureNotDisposed();
    _rust.setDefaultReplayGain(gainDb: gainDb, peak: peak);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Sets ReplayGain calculation mode.
  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    _player._ensureNotDisposed();
    _rust.setReplayGainMode(mode: mode.index);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Configures resilience behavior when audio playback devices change.
  Future<void> setPauseOnDeviceChange(bool enabled) async {
    _player._ensureNotDisposed();
    _rust.setPauseOnDeviceChange(enabled: enabled);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  /// Updates playback buffer period size.
  Future<void> setBufferSize(int size) async {
    _player._ensureNotDisposed();
    if (size < 0) {
      throw ArgumentError.value(
        size,
        'bufferSize',
        'Buffer size must be non-negative',
      );
    }
    _rust.setBufferSize(bufferSizeFrames: size);
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
    _player._ensureNotDisposed();
    final rustEffects = <rust_types.RustAudioEffect>[];
    for (final effect in effects) {
      final rustSource = _toRustSource(effect.source, 0);
      if (effect.source.isMemory) {
        effect.source._clearBytes();
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
    _player.state._loadedEffectIds =
        List.unmodifiable(_rust.getLoadedEffectIds());
    _player.state._allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
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
    _player._ensureNotDisposed();
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
    _player.state._loadedEffectIds =
        List.unmodifiable(_rust.getLoadedEffectIds());
    _player.state._allocatedRamBytes = _rust.getAllocatedRamBytes().toInt();
    _player.state._activeVoicesCount = _rust.getActiveVoicesCount().toInt();
    return Voice(voiceId, this);
  }

  /// Stops an active polyphonic voice with a linear fade-out.
  Future<void> _stopVoice(
    int voiceId, {
    Duration fadeOut = const Duration(milliseconds: 5),
  }) async {
    _player._ensureNotDisposed();
    _rust.stopEffect(
      voiceId: voiceId,
      fadeOutMs: BigInt.from(fadeOut.inMilliseconds),
    );
    _player.state._activeVoicesCount = _rust.getActiveVoicesCount().toInt();
  }

  /// Stops all currently rendering polyphonic effect voices.
  Future<void> stopAllEffects({
    Duration fadeOut = const Duration(milliseconds: 5),
  }) async {
    _player._ensureNotDisposed();
    _rust.stopAllEffects(fadeOutMs: BigInt.from(fadeOut.inMilliseconds));
    _player.state._activeVoicesCount = _rust.getActiveVoicesCount().toInt();
  }

  /// Modulates the volume of an active polyphonic voice in real time (`>= 0.0`).
  Future<void> _setVoiceVolume(int voiceId, double volume) async {
    _player._ensureNotDisposed();
    if (volume.isNaN || volume.isInfinite || volume < 0.0) {
      throw ArgumentError.value(volume, 'volume', 'Voice volume must be >= 0.0');
    }
    _rust.setEffectVolume(voiceId: voiceId, volume: volume.toDouble());
  }

  /// Modulates the pitch of an active polyphonic voice in real time (`> 0.0`).
  Future<void> _setVoicePitch(int voiceId, double pitch) async {
    _player._ensureNotDisposed();
    if (pitch.isNaN || pitch.isInfinite || pitch <= 0.0) {
      throw ArgumentError.value(pitch, 'pitch', 'Voice pitch must be > 0.0');
    }
    _rust.setEffectPitch(voiceId: voiceId, pitch: pitch.toDouble());
  }

  /// Modulates the stereo balance of an active polyphonic voice (`-1.0` to `1.0`).
  Future<void> _setVoiceBalance(int voiceId, double balance) async {
    _player._ensureNotDisposed();
    _rust.setEffectBalance(voiceId: voiceId, balance: balance.toDouble());
  }

  /// Updates the 3D position and velocity of an active polyphonic voice.
  Future<void> _setVoiceEmitter(
    int voiceId,
    SpatialEmitter emitter,
  ) async {
    _player._ensureNotDisposed();
    _rust.setEffectEmitter(
      voiceId: voiceId,
      emitter: _toRustEmitter(emitter),
    );
  }

  /// Updates the 3D spatial position, orientation, and velocity of the global listener.
  Future<void> setListener(SpatialListener listener) async {
    _player._ensureNotDisposed();
    _rust.setListener(listener: _toRustListener(listener));
  }

  /// Calibrates the global physics of the 3D Doppler effect.
  Future<void> setDopplerParameters({
    double factor = 1.0,
    double speedOfSound = 343.3,
  }) async {
    _player._ensureNotDisposed();
    _rust.setDopplerParameters(
      factor: factor,
      speedOfSound: speedOfSound,
    );
  }

  // =========================================================================
  // Multi-Destination Output Matrix & Recording
  // =========================================================================

  /// Sets the active outputs for this player instance, replacing any existing ones.
  ///
  /// If [outputs] is empty (`{}`), all physical audio output devices are closed
  /// and zero audio is rendered to hardware.
  ///
  /// ### Physical Endpoint Collision Resolution
  /// If [outputs] contains both `'AUTO'` and an explicit device identifier that resolves
  /// to the same physical OS endpoint, the native Rust audio engine deduplicates the
  /// hardware endpoint so that only one hardware context is opened. The `'AUTO'` output
  /// configuration takes strict precedence over the specific device configuration.
  /// The declared set in [PlayerState.outputs] and [PlayerStream.outputs] remains intact.
  Future<void> setOutputs(Set<AudioOutput> outputs) async {
    _player._ensureNotDisposed();
    final rustOutputs = outputs.map((out) {
      return rust_types.RustAudioOutput(
        deviceId: out.deviceId,
        source: out.source.value,
      );
    }).toList();
    _rust.setOutputs(outputs: rustOutputs);
  }

  /// Adds an output destination to this player's active outputs.
  Future<void> addOutput(AudioOutput output) async {
    _player._ensureNotDisposed();
    _rust.addOutput(
      output: rust_types.RustAudioOutput(
        deviceId: output.deviceId,
        source: output.source.value,
      ),
    );
  }

  /// Removes an output destination from this player's active outputs.
  Future<void> removeOutput(AudioOutput output) async {
    _player._ensureNotDisposed();
    _rust.removeOutput(
      output: rust_types.RustAudioOutput(
        deviceId: output.deviceId,
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
    _player._ensureNotDisposed();
    await _rust.startRecording(
      path: path,
      format: format.index,
      source: source.value,
    );
    await Future<void>.delayed(Duration.zero);
  }

  /// Stops live disk recording and returns an immutable [RecordingResult].
  Future<RecordingResult> stopRecording() async {
    _player._ensureNotDisposed();
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
  // Input Routing Matrix & Multi-Capture
  // =========================================================================

  rust_types.RustAudioInputConfig _toRustInputConfig(AudioInputConfig config) {
    if (config.volume.isNaN || config.volume.isInfinite || config.volume < 0.0) {
      throw ArgumentError.value(
        config.volume,
        'volume',
        'Input volume must be >= 0.0',
      );
    }
    if (config.monitorVolume.isNaN ||
        config.monitorVolume.isInfinite ||
        config.monitorVolume < 0.0) {
      throw ArgumentError.value(
        config.monitorVolume,
        'monitorVolume',
        'Monitor volume must be >= 0.0',
      );
    }
    return rust_types.RustAudioInputConfig(
      volume: config.volume,
      ducking: config.ducking?.toRust(),
      monitorDirect: config.monitorDirect,
      monitorVolume: config.monitorVolume,
    );
  }

  rust_types.RustAudioInput _toRustInput(AudioInput input) {
    return rust_types.RustAudioInput(
      deviceId: input.deviceId,
      config: _toRustInputConfig(input.config),
    );
  }

  /// Sets the active audio capture inputs, reconciling them in the Rust engine.
  ///
  /// If [inputs] is empty (`{}`), all capture nodes are closed.
  ///
  /// ### Physical Endpoint Collision Resolution
  /// If [inputs] contains both `'AUTO'` and an explicit device identifier that resolves
  /// to the same physical OS capture endpoint, the native Rust audio engine deduplicates the
  /// hardware endpoint so that only one capture stream is opened. The `'AUTO'` input
  /// configuration takes strict precedence over the specific device configuration.
  /// The declared set in [PlayerState.inputs] and [PlayerStream.inputs] remains intact.
  Future<void> setInputs(Set<AudioInput> inputs) async {
    _player._ensureNotDisposed();
    final rustList = inputs.map(_toRustInput).toList();
    _rust.setInputs(inputs: rustList);
  }

  /// Adds an audio input capture node to the player.
  ///
  /// Throws [StateError] if an input with the same device identifier is already active.
  Future<void> addInput(AudioInput input) async {
    _player._ensureNotDisposed();
    if (_player.state.inputs.any((i) => i.deviceId == input.deviceId)) {
      throw StateError(
        'Input with deviceId ${input.deviceId} is already active. Use configureInput to modify it.',
      );
    }
    _rust.addInput(input: _toRustInput(input));
  }

  /// Removes an audio input capture node from the player.
  Future<void> removeInput(AudioInput input) async {
    _player._ensureNotDisposed();
    _rust.removeInput(input: _toRustInput(input));
  }

  /// Modulates runtime parameters of an already active audio input capture node without reopening hardware.
  ///
  /// Throws [StateError] if no active input exists for the target device.
  Future<void> configureInput(
    AudioInputConfig config, {
    String deviceId = 'AUTO',
    AudioDevice? device,
  }) async {
    _player._ensureNotDisposed();
    final targetId = device != null ? device.id : deviceId;
    if (!_player.state.inputs.any((i) => i.deviceId == targetId)) {
      throw StateError(
        'Cannot configure input: deviceId $targetId is not currently active.',
      );
    }
    _rust.configureInput(
      deviceId: targetId,
      config: _toRustInputConfig(config),
    );
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
