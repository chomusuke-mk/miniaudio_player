import 'dart:typed_data';

import '../equalizer.dart';
import '../network/network_audio_streamer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'engine_item.dart';
import 'loop_mode.dart';
import 'miniaudio_engine.dart';
import 'silence_skip_config.dart';

/// Action interface executing asynchronous playback, queue navigation,
/// crossfade configuration, and DSP controls on [MiniaudioEngine].
///
/// Mirrors the full control surface of [PlayerAction] while adding first-class
/// queue management, shuffle/loop policies, automatic/manual crossfading,
/// per-track ReplayGain normalization, and Infinite Mix controls.
class EngineAction<T> {
  final MiniaudioEngine<T> _engine;

  /// Creates an [EngineAction] facade bound to [_engine].
  EngineAction(this._engine);

  /// Active network audio streamer instance on the currently active deck, if any.
  NetworkAudioStreamer? get activeStreamer => _engine.activeStreamer;

  // --------------------------------------------------------------------------
  // Single-Source & Queue Opening
  // --------------------------------------------------------------------------

  /// Replaces the queue with [items] and prepares the initial entry at [startIndex]
  /// without starting playback. Call [play] to start playback.
  ///
  /// - [startIndex]: Initial zero-based index to load (defaults to `0`, or a
  ///   uniform random index if [shuffle] is `true` and [startIndex] is `null`).
  /// - [shuffle]: Whether to initialize the queue in Fisher-Yates shuffled order.
  Future<void> openQueue(
    List<EngineItem<T>> items, {
    int? startIndex,
    bool shuffle = false,
  }) =>
      _engine.openQueueInternal(
        items,
        startIndex: startIndex,
        shuffle: shuffle,
      );

  /// Coerces a list of flexible [sources] ([EngineItem], [AudioSource],
  /// [String] file path / URL / asset, [Uri], [Uint8List], or `FileSystemEntity`)
  /// into [EngineItem]s and opens them as the active queue without starting
  /// playback. Call [play] to start playback.
  Future<void> openSources(
    List<dynamic> sources, {
    int? startIndex,
    bool shuffle = false,
  }) {
    final items = [
      for (var i = 0; i < sources.length; i++)
        EngineItem<T>.fromDynamic(sources[i], position: i),
    ];
    return _engine.openQueueInternal(
      items,
      startIndex: startIndex,
      shuffle: shuffle,
    );
  }

  /// Opens a single audio [source] as a 1-item queue without starting playback.
  /// Call [play] to start playback.
  ///
  /// Accepts an [EngineItem], [AudioSource], [String] path/URL/asset, [Uri],
  /// [Uint8List], or `FileSystemEntity`.
  Future<void> open(
    dynamic source, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
  }) {
    final item = EngineItem<T>.fromDynamic(
      source,
      data: data,
      replayGainDb: replayGainDb,
      replayPeak: replayPeak,
      headers: headers,
      isLive: isLive,
      bufferAhead: bufferAhead,
    );
    return _engine.openQueueInternal(
      [item],
      startIndex: 0,
      shuffle: false,
    );
  }

  /// Opens a single local filesystem [filePath] as a 1-item queue without
  /// starting playback. Call [play] to start playback.
  Future<void> openFile(
    String filePath, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) =>
      open(
        EngineItem<T>.file(
          filePath,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );

  /// Opens a single HTTP/HTTPS [uri] stream (progressive or [isLive] livestream)
  /// as a 1-item queue without starting playback. Call [play] to start playback.
  Future<void> openUrl(
    Uri uri, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) =>
      open(
        EngineItem<T>.uri(
          uri,
          headers: headers,
          isLive: isLive,
          bufferAhead: bufferAhead,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );

  /// Opens an in-memory [bytes] audio buffer as a 1-item queue without starting
  /// playback. Call [play] to start playback.
  Future<void> openMemory(
    Uint8List bytes, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) =>
      open(
        EngineItem<T>.memory(
          bytes,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );

  /// Opens a bundled application [assetKey] as a 1-item queue without starting
  /// playback. Call [play] to start playback.
  Future<void> openAsset(
    String assetKey, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) =>
      open(
        EngineItem<T>.asset(
          assetKey,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );

  // --------------------------------------------------------------------------
  // Transport Controls
  // --------------------------------------------------------------------------

  /// Starts or resumes playback of the active deck (or active crossfade).
  ///
  /// If the queue had previously reached completion (`EnginePhase.completed`),
  /// restarts from index `0`.
  Future<void> play() => _engine.playInternal();

  /// Pauses playback of the active deck (and freezes any active crossfade ramp).
  Future<void> pause() => _engine.pauseInternal();

  /// Toggles between [play] and [pause].
  Future<void> togglePlayPause() => _engine.togglePlayPauseInternal();

  /// Stops playback on both decks and resets position to the beginning.
  Future<void> stop() => _engine.stopInternal();

  /// Seeks to [position] on the active track.
  ///
  /// - If an automatic crossfade is in flight (`EnginePhase.autoCrossfading`),
  ///   reverts the tentative transition back to the outgoing track and seeks it.
  /// - If a manual crossfade is in flight (`EnginePhase.manualCrossfading`),
  ///   finalizes the transition immediately onto the incoming track and seeks it.
  /// - Safe no-op if the active track is a continuous livestream.
  Future<void> seek(Duration position) => _engine.seekInternal(position);

  // --------------------------------------------------------------------------
  // Queue Navigation & Mutations
  // --------------------------------------------------------------------------

  /// Advances to the next item in the queue.
  ///
  /// If an automatic crossfade into the next item is already running, promotes
  /// that fade into a committed manual transition and caps its remaining
  /// duration to [CrossfadeConfig.manualDuration] without reopening the file.
  Future<void> next() => _engine.nextInternal();

  /// Steps to the previous item in the queue, or restarts the current track at
  /// `0:00` if playback position exceeds `3 seconds` (or at index `0` in
  /// [LoopMode.off]).
  Future<void> previous() => _engine.previousInternal();

  /// Jumps directly to [index] in the active queue, preserving current playback state.
  Future<void> skipToIndex(int index) => _engine.skipToIndexInternal(index);

  /// Inserts [item] immediately after the currently playing item.
  ///
  /// Automatically invalidates any tentative automatic crossfade if the next
  /// candidate item changed.
  Future<void> insertNext(EngineItem<T> item) =>
      _engine.insertNextInternal(item);

  /// Coerces [source] into an [EngineItem] and inserts it immediately after
  /// the currently playing item.
  Future<void> insertNextSource(
    dynamic source, {
    T? data,
    double? replayGainDb,
    double? replayPeak,
  }) =>
      _engine.insertNextInternal(
        EngineItem<T>.fromDynamic(
          source,
          data: data,
          replayGainDb: replayGainDb,
          replayPeak: replayPeak,
        ),
      );

  /// Appends [items] to the end of the active queue.
  Future<void> append(List<EngineItem<T>> items) =>
      _engine.appendInternal(items);

  /// Coerces [sources] into [EngineItem]s and appends them to the end of the queue.
  Future<void> appendSources(List<dynamic> sources) {
    final items = [
      for (var i = 0; i < sources.length; i++)
        EngineItem<T>.fromDynamic(sources[i]),
    ];
    return _engine.appendInternal(items);
  }

  /// Removes the item at [index] from the queue.
  ///
  /// - If a distant item is removed, playback and any unaffected crossfade
  ///   continue without interruption.
  /// - If the candidate next item is removed during an automatic crossfade,
  ///   the tentative crossfade is cleanly aborted.
  /// - If the currently playing item is removed, transitions to the item that
  ///   takes its place (or stops if the queue becomes empty).
  Future<void> removeAt(int index) => _engine.removeAtInternal(index);

  /// Moves the queue item at [from] to [to] without interrupting playback.
  ///
  /// Automatically cancels any tentative automatic crossfade if the candidate
  /// next item changed.
  Future<void> reorder(int from, int to) => _engine.reorderInternal(from, to);

  /// Clears the queue.
  ///
  /// When [keepCurrent] is `true` (default) and a track is currently loaded,
  /// retains the active track as the sole entry at index `0` without stopping
  /// playback. When `false` (or when idle), stops both decks and empties the queue.
  Future<void> clearQueue({bool keepCurrent = true}) =>
      _engine.clearQueueInternal(keepCurrent: keepCurrent);

  // --------------------------------------------------------------------------
  // Shuffle, Loop, Crossfade, ReplayGain & Infinite Mix Policies
  // --------------------------------------------------------------------------

  /// Explicitly enables or disables Fisher-Yates shuffle mode.
  Future<void> setShuffle(bool enabled) => _engine.setShuffleInternal(enabled);

  /// Toggles Fisher-Yates shuffle mode on or off.
  Future<bool> toggleShuffle() => _engine.toggleShuffleInternal();

  /// Sets the queue repeat policy ([LoopMode.off], [LoopMode.one], [LoopMode.all]).
  Future<void> setLoopMode(LoopMode mode) => _engine.setLoopModeInternal(mode);

  /// Cycles the queue repeat policy in order: `off -> all -> one -> off`.
  Future<LoopMode> cycleLoopMode() => _engine.cycleLoopModeInternal();

  /// Updates the complete [CrossfadeConfig] (automatic duration, manual
  /// duration, and interpolation curve).
  Future<void> setCrossfadeConfig(CrossfadeConfig config) =>
      _engine.setCrossfadeConfigInternal(config);

  /// Updates the automatic end-of-track crossfade [duration] (`0s..12s`).
  Future<void> setCrossfadeDuration(Duration duration) =>
      _engine.setCrossfadeConfigInternal(
        _engine.state.crossfadeConfig.copyWith(duration: duration),
      );

  /// Updates the manual skip crossfade [manualDuration] (`0s..12s`).
  Future<void> setManualCrossfadeDuration(Duration manualDuration) =>
      _engine.setCrossfadeConfigInternal(
        _engine.state.crossfadeConfig.copyWith(manualDuration: manualDuration),
      );

  /// Updates the crossfade gain interpolation [curve] ([CrossfadeCurve.equalPower]
  /// or [CrossfadeCurve.linear]).
  Future<void> setCrossfadeCurve(CrossfadeCurve curve) =>
      _engine.setCrossfadeConfigInternal(
        _engine.state.crossfadeConfig.copyWith(curve: curve),
      );

  /// Enables or disables automatic per-item ReplayGain loudness normalization.
  Future<void> setVolumeNormalization(bool enabled) =>
      _engine.setVolumeNormalizationInternal(enabled);

  /// Enables or disables proactive Infinite Mix lookahead prefetching.
  Future<void> setInfiniteMix(bool enabled) =>
      _engine.setInfiniteMixInternal(enabled);

  // --------------------------------------------------------------------------
  // Volume, Speed, Pitch, Device & Studio DSP Suite
  // --------------------------------------------------------------------------

  /// Sets the master audio volume level (`0.0` to `2.0`, default `1.0`).
  ///
  /// Dynamically scales active crossfade envelopes without cancelling the fade.
  Future<void> setVolume(double volume) => _engine.setVolumeInternal(volume);

  /// Sets the playback speed multiplier (`0.1` to `4.0`, default `1.0`).
  Future<void> setRate(double rate) => _engine.setRateInternal(rate);

  /// Sets the audio pitch multiplier (`0.5` to `2.0`, default `1.0`).
  Future<void> setPitch(double pitch) => _engine.setPitchInternal(pitch);

  /// Sets the internal native buffer size in frames (`0` = native default) on
  /// both decks.
  Future<void> setBufferSize(int bufferSize) =>
      _engine.setBufferSizeInternal(bufferSize);

  /// Applies a 10-band [Equalizer] configuration across both decks.
  Future<void> setEqualizer(Equalizer equalizer) =>
      _engine.setEqualizerInternal(equalizer);

  /// Updates a single equalizer band at [index] (`0..9`) with [gainDb] (`-24.0..+24.0`).
  Future<void> setEqualizerBand(int index, double gainDb) {
    if (index < 0 || index >= 10) {
      throw RangeError.range(index, 0, 9, 'index');
    }
    final bands = List<double>.from(_engine.state.equalizer.toList());
    bands[index] = gainDb.clamp(-24.0, 24.0);
    return _engine.setEqualizerInternal(Equalizer.fromList(bands));
  }

  /// Resets all 10 equalizer bands to `0.0 dB` ([Equalizer.flat]).
  Future<void> resetEqualizer() =>
      _engine.setEqualizerInternal(Equalizer.flat);

  /// Sets the active audio output [device] across both decks.
  Future<void> setDevice(AudioDevice device) =>
      _engine.setDeviceInternal(device);

  /// Enables or disables silence skipping across both decks.
  Future<void> setSkipSilence(
    bool enabled, {
    SilenceSkipMode mode = SilenceSkipMode.continuous,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) =>
      _engine.setSkipSilenceInternal(
        enabled,
        mode: mode,
        thresholdDb: thresholdDb,
        minSilenceDuration: minSilenceDuration,
        padding: padding,
      );

  /// Applies a complete [SilenceSkipConfig] across both decks.
  Future<void> setSilenceConfig(SilenceSkipConfig config) =>
      _engine.setSilenceConfigInternal(config);

  /// Forces real-time visualizer DSP extraction enabled or disabled.
  Future<void> setVisualizerEnabled(bool enabled) =>
      _engine.setVisualizerOverrideInternal(enabled);

  /// Clears any manual visualizer override, reverting to reactive on-demand
  /// activation based on [EngineStream.visualizer] listeners.
  Future<void> clearVisualizerOverride() =>
      _engine.setVisualizerOverrideInternal(null);

  /// Manually applies ReplayGain normalization to the currently active deck.
  Future<void> setReplayGain({
    required double gainDb,
    double? peak,
    double preampDb = 0.0,
    bool preventClipping = true,
  }) =>
      _engine.setReplayGainInternal(
        gainDb: gainDb,
        peak: peak,
        preampDb: preampDb,
        preventClipping: preventClipping,
      );

  /// Clears ReplayGain normalization on the active deck back to unity gain (`0.0 dB`).
  Future<void> clearReplayGain() => _engine.clearReplayGainInternal();

  /// Sets standalone manual preamp gain in decibels (`-12.0` to `+12.0` dB)
  /// across both decks.
  Future<void> setPreamp(double preampDb) =>
      _engine.setPreampInternal(preampDb);

  /// Sets stereo channel balance (`-1.0` full left, `0.0` center, `+1.0` full right)
  /// across both decks.
  Future<void> setBalance(double pan) => _engine.setBalanceInternal(pan);

  /// Enables or disables mono downmixing across both decks.
  Future<void> setMono(bool enabled) => _engine.setMonoInternal(enabled);

  /// Configures headphone binaural crossfeed ([CrossfeedMode]) across both decks.
  Future<void> setCrossfeed(CrossfeedMode mode) =>
      _engine.setCrossfeedInternal(mode);

  /// Configures the stereo widener / spatializer across both decks.
  Future<void> setSpatializer({
    required bool enabled,
    double width = 1.3,
  }) =>
      _engine.setSpatializerInternal(enabled: enabled, width: width);

  /// Enables or disables the True-Peak soft-knee output limiter across both decks.
  Future<void> setLimiter(bool enabled) => _engine.setLimiterInternal(enabled);

  /// Configures studio-grade algorithmic reverberation ([Reverb]) across both decks.
  Future<void> setReverb(Reverb config) => _engine.setReverbInternal(config);

  /// Updates specific parameters of the active reverb effect while preserving others.
  Future<void> updateReverb({
    bool? enabled,
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
  }) {
    final current = _engine.state.reverb;
    return _engine.setReverbInternal(
      current.copyWith(
        enabled: enabled,
        roomSize: roomSize,
        damping: damping,
        width: width,
        wet: wet,
        dry: dry,
      ),
    );
  }
}
