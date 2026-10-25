// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/audio_byte_provider.dart';
import '../loader/unified_audio_loader.dart';
import '../platform/fs_helper.dart';
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

  /// Alias for [activeLoader].
  UnifiedAudioLoader? get activeStreamer => _activeLoader;

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

  /// Prepares an audio source for playback.
  ///
  /// Accepts:
  /// - An [AudioSource] instance ([FileAudioSource], [AssetAudioSource],
  ///   [MemoryAudioSource], [NetworkAudioSource], [LiveStreamAudioSource],
  ///   [CustomAudioSource]).
  /// - An [AudioByteProvider] instance.
  /// - A [String] path or URI (`file://...`, `asset://...`, `assets/...`,
  ///   `http://...`, `https://...`, or standard file path).
  /// - A [Uri] object.
  /// - A [Uint8List] containing raw audio file bytes in memory.
  /// - A `FileSystemEntity` (e.g. `File`).
  Future<void> open(
    dynamic source, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    Duration? bufferBehind,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
  }) async {
    _player.ensureNotDisposed();

    final effectiveAhead = bufferAhead;
    final effectiveBehind = bufferBehind;

    if (source is AudioSource) {
      switch (source) {
        case FileAudioSource s:
          return openFile(
            s.filePath,
            bufferAhead: effectiveAhead ?? bufferLocalDuration,
            bufferBehind: effectiveBehind,
          );
        case AssetAudioSource s:
          return openAsset(
            s.assetKey,
            package: s.package,
            bufferAhead: effectiveAhead ?? bufferLocalDuration,
            bufferBehind: effectiveBehind,
          );
        case MemoryAudioSource s:
          return openMemory(
            s.bytes,
            uri: s.uri,
            contentType: s.mimeType,
            bufferAhead: effectiveAhead ?? bufferLocalDuration,
            bufferBehind: effectiveBehind,
          );
        case LiveStreamAudioSource s:
          return openUrl(
            s.uri,
            headers: headers ?? s.headers,
            isLive: true,
            bufferAhead:
                effectiveAhead ?? bufferLiveStreamDuration ?? s.jitterBuffer,
            bufferBehind: effectiveBehind,
          );
        case NetworkAudioSource s:
          return openUrl(
            s.uri,
            headers: headers ?? s.headers,
            isLive: isLive || s.isLive,
            bufferAhead: effectiveAhead ??
                (s.isLive ? bufferLiveStreamDuration : bufferNetworkDuration) ??
                s.bufferAhead,
            bufferBehind: effectiveBehind,
          );
        case ResolvingAudioSource s:
          return openResolving(
            s,
            headers: headers ?? s.headers,
            isLive: isLive || s.isLive,
            bufferAhead: effectiveAhead ?? s.bufferAhead,
            bufferBehind: effectiveBehind,
            bufferLocalDuration: bufferLocalDuration,
            bufferNetworkDuration: bufferNetworkDuration,
            bufferLiveStreamDuration: bufferLiveStreamDuration,
          );
        case CustomAudioSource s:
          return openProvider(
            s.provider,
            bufferAhead: effectiveAhead,
            bufferBehind: effectiveBehind,
          );
      }
    } else if (source is AudioByteProvider) {
      return openProvider(
        source,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
      );
    } else if (source is Uint8List) {
      return openMemory(
        source,
        bufferAhead: effectiveAhead ?? bufferLocalDuration,
        bufferBehind: effectiveBehind,
      );
    } else if (source is Uri || source is String) {
      if (source is String && source.trim().isEmpty) {
        return openFile(
          '',
          bufferAhead: effectiveAhead ?? bufferLocalDuration,
          bufferBehind: effectiveBehind,
        );
      }
      final resolvedSource = AudioSource.uri(
        source,
        headers: headers,
        isLive: isLive,
        bufferAhead: effectiveAhead,
      );
      return open(
        resolvedSource,
        headers: headers,
        isLive: isLive,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
        bufferLocalDuration: bufferLocalDuration,
        bufferNetworkDuration: bufferNetworkDuration,
        bufferLiveStreamDuration: bufferLiveStreamDuration,
      );
    } else if (isFsEntity(source)) {
      final path = getFsPath(source);
      if (path != null) {
        return openFile(
          path,
          bufferAhead: effectiveAhead ?? bufferLocalDuration,
          bufferBehind: effectiveBehind,
        );
      }
      throw ArgumentError.value(
        source,
        'source',
        'Unsupported audio source type',
      );
    } else {
      throw ArgumentError.value(
        source,
        'source',
        'Unsupported audio source type',
      );
    }
  }

  /// Opens a custom [AudioByteProvider] through the unified loader pipeline.
  Future<void> openProvider(
    AudioByteProvider provider, {
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) {
    _player.ensureNotDisposed();
    if (provider.sourceId.trim().isEmpty) {
      throw const MiniaudioPlayerException('Cannot open provider with empty sourceId');
    }
    final effectiveAhead = bufferAhead ??
        (provider.isLiveStream
            ? _player.bufferLiveStreamDuration
            : (provider.isNetwork
                ? _player.bufferNetworkDuration
                : _player.bufferLocalDuration));
    final effectiveBehind = bufferBehind ??
        (provider.isLiveStream
            ? _player.bufferBehindLiveStreamDuration
            : (provider.isNetwork
                ? _player.bufferBehindNetworkDuration
                : _player.bufferBehindLocalDuration));

    return _openGuarded(
      (gen) => _startUnifiedLoader(
        provider,
        gen: gen,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
      ),
    );
  }

  /// Opens a [ResolvingAudioSource] (`content://`, `fd://`, `/proc/self/fd/<fd>`, or custom URI)
  /// through the Capability Promotion pipeline.
  Future<void> openResolving(
    ResolvingAudioSource source, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    Duration? bufferBehind,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
  }) {
    _player.ensureNotDisposed();
    if (source.rejectedByPathTraversal) {
      return _openGuarded((_) async {
        throw MiniaudioPlayerException(
          'Path traversal rejected in URI: ${source.uri}',
          errorCode: MapResult.errorAccessDenied,
        );
      });
    }
    return _openGuarded((gen) async {
      final resolvingProvider = ResolvingByteProvider(
        source.uri,
        canonicalFilePath: source.canonicalFilePath,
        headers: headers ?? source.headers,
        isLive: isLive || source.isLive,
        ownFd: source.ownFd,
        rejectedByPathTraversal: source.rejectedByPathTraversal,
      );
      final promoted = await resolvingProvider.resolveProvider(
        isCancelled: () => _openGeneration != gen || _player.isDisposed,
      );
      if (_openGeneration != gen || _player.isDisposed) {
        await promoted.close();
        return;
      }
      final effectiveAhead = bufferAhead ??
          source.bufferAhead ??
          (promoted.isLiveStream
              ? (bufferLiveStreamDuration ?? _player.bufferLiveStreamDuration)
              : (promoted.isNetwork
                  ? (bufferNetworkDuration ?? _player.bufferNetworkDuration)
                  : (bufferLocalDuration ?? _player.bufferLocalDuration)));
      final effectiveBehind = bufferBehind ??
          (promoted.isLiveStream
              ? _player.bufferBehindLiveStreamDuration
              : (promoted.isNetwork
                  ? _player.bufferBehindNetworkDuration
                  : _player.bufferBehindLocalDuration));
      await _startUnifiedLoader(
        promoted,
        gen: gen,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
      );
    });
  }

  /// Opens an audio source backed by an open native file descriptor (`int fd`),
  /// promoting to a Level 1 [FileByteProvider] if `/proc/self/fd/<fd>` resolves to
  /// a directly readable regular file, or using a Level 2 [FdByteProvider] otherwise.
  Future<void> openFd(
    int fd, {
    bool ownFd = true,
    Uri? uri,
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) {
    _player.ensureNotDisposed();
    if (fd < 0) {
      return _openGuarded((_) async {
        throw MiniaudioPlayerException(
          'Invalid file descriptor: $fd',
          errorCode: MapResult.errorInvalidArgs,
        );
      });
    }
    return _openGuarded((gen) async {
      final promoted = await UriCapabilityResolver.promoteOrWrapFd(
        fd,
        uri: uri ?? Uri.parse('fd://$fd'),
        ownFd: ownFd,
        isCancelled: () => _openGeneration != gen || _player.isDisposed,
      );
      if (_openGeneration != gen || _player.isDisposed) {
        await promoted.close();
        return;
      }
      final effectiveAhead = bufferAhead ??
          (promoted.isLiveStream
              ? _player.bufferLiveStreamDuration
              : _player.bufferLocalDuration);
      final effectiveBehind = bufferBehind ??
          (promoted.isLiveStream
              ? _player.bufferBehindLiveStreamDuration
              : _player.bufferBehindLocalDuration);
      await _startUnifiedLoader(
        promoted,
        gen: gen,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
      );
    });
  }

  /// Opens a local filesystem audio file.
  Future<void> openFile(
    String filePath, {
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) {
    _player.ensureNotDisposed();
    if (filePath.isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty file path');
    }
    return _openGuarded(
      (gen) => _startUnifiedLoader(
        FileByteProvider(filePath),
        gen: gen,
        bufferAhead: bufferAhead ?? _player.bufferLocalDuration,
        bufferBehind: bufferBehind ?? _player.bufferBehindLocalDuration,
      ),
    );
  }

  /// Opens an audio file directly from an in-memory byte buffer (RAM).
  Future<void> openMemory(
    Uint8List bytes, {
    Uri? uri,
    String? contentType,
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) {
    _player.ensureNotDisposed();
    if (bytes.isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty byte buffer');
    }
    return _openGuarded(
      (gen) => _startUnifiedLoader(
        MemoryByteProvider(bytes, uri: uri, contentType: contentType),
        gen: gen,
        bufferAhead: bufferAhead ?? _player.bufferLocalDuration,
        bufferBehind: bufferBehind ?? _player.bufferBehindLocalDuration,
      ),
    );
  }

  /// Opens an asset directly without copying to disk.
  Future<void> openAsset(
    String assetPath, {
    String? package,
    AssetBytesLoader? loader,
    Duration? bufferAhead,
    Duration? bufferBehind,
  }) {
    _player.ensureNotDisposed();
    if (assetPath.isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty asset path');
    }
    return _openGuarded(
      (gen) => _startUnifiedLoader(
        AssetByteProvider(assetPath, package: package, loader: loader),
        gen: gen,
        bufferAhead: bufferAhead ?? _player.bufferLocalDuration,
        bufferBehind: bufferBehind ?? _player.bufferBehindLocalDuration,
      ),
    );
  }

  /// Opens a remote audio URL (HTTP/HTTPS) or live stream with progressive streaming.
  Future<void> openUrl(
    dynamic urlOrUri, {
    Map<String, String>? headers,
    bool isLive = false,
    Duration? bufferAhead,
    Duration? bufferBehind,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
  }) {
    _player.ensureNotDisposed();
    if (urlOrUri == null) {
      throw ArgumentError.notNull('urlOrUri');
    }
    if (urlOrUri is String && urlOrUri.trim().isEmpty) {
      throw const MiniaudioPlayerException('Cannot open empty URL string');
    }
    if (urlOrUri is! Uri && urlOrUri is! String) {
      throw ArgumentError.value(urlOrUri, 'urlOrUri', 'Expected Uri or String');
    }

    Uri uri = urlOrUri is Uri
        ? urlOrUri
        : Uri.parse((urlOrUri as String).trim());
    final scheme = uri.scheme.toLowerCase();
    bool effectiveIsLive = isLive;
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
        urlOrUri,
        'urlOrUri',
        'Invalid URL scheme: "${uri.scheme}" (expected http, https, icy, icyx, or blob)',
      );
    }
    final effectiveAhead = bufferAhead ??
        (effectiveIsLive
            ? (bufferLiveStreamDuration ?? _player.bufferLiveStreamDuration)
            : (bufferNetworkDuration ?? _player.bufferNetworkDuration));
    final effectiveBehind = bufferBehind ??
        (effectiveIsLive
            ? _player.bufferBehindLiveStreamDuration
            : _player.bufferBehindNetworkDuration);

    return _openGuarded(
      (gen) => _startUnifiedLoader(
        effectiveIsLive
            ? LiveStreamByteProvider(
                uri,
                headers: headers,
                onIcyMetaBytes: setIcyMeta,
              )
            : NetworkByteProvider(
                uri,
                headers: headers,
                onIcyMetaBytes: setIcyMeta,
              ),
        gen: gen,
        bufferAhead: effectiveAhead,
        bufferBehind: effectiveBehind,
      ),
    );
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

  /// Updates specific parameters of the silence detector while keeping existing values.
  Future<void> configureSilenceSkip({
    SilenceSkipMode? mode,
    double? thresholdDb,
    Duration? minSilenceDuration,
    Duration? padding,
  }) async {
    final current = _player.state.silenceConfig;
    final updated = current.copyWith(
      mode: mode,
      thresholdDb: thresholdDb,
      minSilenceDuration: minSilenceDuration,
      padding: padding,
    );
    await setSilenceConfig(updated);
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
    double preampDb = 0.0,
    bool preventClipping = true,
  }) async {
    _player.ensureNotDisposed();
    final cfg = ReplayGainConfig(
      enabled: true,
      gainDb: gainDb,
      peak: (peak != null && peak > 0.0) ? peak : 0.0,
      preampDb: preampDb,
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

  /// Updates specific parameters of the active reverb effect while preserving others.
  Future<void> configureReverb({
    bool? enabled,
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
  }) async {
    final current = _player.state.reverb;
    final updated = current.copyWith(
      enabled: enabled,
      roomSize: roomSize,
      damping: damping,
      width: width,
      wet: wet,
      dry: dry,
    );
    await setReverb(updated);
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
