import 'dart:async';
import 'dart:typed_data';

import '../api/audio_analysis_result.dart';
import '../api/audio_device.dart';
import '../api/buffered_range.dart';
import '../api/dsp_config.dart';
import '../api/logger.dart';
import '../api/player_exception.dart';
import '../api/player_state.dart';
import '../api/silence_skip_config.dart';
import '../api/spatial.dart';
import '../api/track_metadata.dart';
import '../api/visualizer_data.dart';
import '../equalizer.dart';
import '../reverb.dart';
import '../rust/api/player.dart' as rust;
import '../rust/api/types.dart' as rust_types;
import '../rust/frb_generated.dart';

/// Listener interface receiving deterministic state and telemetry callbacks
/// from a [PlayerBackend].
abstract class PlayerBackendListener {
  void onState(PlaybackState state);
  void onPosition(Duration position);
  void onDuration(Duration duration);
  void onPlaying(bool isPlaying);
  void onBuffering(bool isBuffering);
  void onCompleted(bool isCompleted);
  void onVolume(double volume);
  void onRate(double rate);
  void onPitch(double pitch);
  void onBitrate(int bitrate);
  void onBufferSize(int bufferSize);
  void onSilenceSaved(Duration duration);
  void onSilenceConfig(SilenceSkipConfig config);
  void onBufferedRange(BufferedRange range);
  void onVisualizer(VisualizerData data);
  void onVisualizerEnabled(bool enabled);
  void onDevice(AudioDevice device);
  void onTrackMetadata(AudioTrackMetadata? metadata);
  void onEqualizer(Equalizer equalizer);
  void onPreamp(double preampDb);
  void onReplayGain(ReplayGainConfig config);
  void onBalance(double balance);
  void onMono(bool enabled);
  void onCrossfeed(CrossfeedMode mode);
  void onSpatializer({required bool enabled, required double width});
  void onReverb(Reverb reverb);
  void onLimiter(bool enabled);
  void onError(String message, int errorCode);
}

/// Abstract platform backend contract for single-player audio execution.
abstract class PlayerBackend {
  int get sampleRate;
  int get channels;
  int get pinnedHeadSize;

  Uint8List? getMetaBytes();

  void setListener(PlayerBackendListener listener);

  void init({
    int sampleRate = 48000,
    int channels = 2,
    int periodSize = 2048,
    String? playbackDeviceId,
  });

  Future<void> openSource(String source, {Map<String, String>? headers});
  Future<void> openMemory(Uint8List bytes);

  Future<void> openCustomStream({
    required int streamId,
    int? totalSize,
    required bool isSeekable,
    required Uint8List initialBytes,
  });

  void supplyCustomBytes({
    required int streamId,
    required int requestId,
    required Uint8List data,
    required bool isEof,
  });

  void notifyCustomError({
    required int streamId,
    required int requestId,
    required String errorMessage,
  });

  Stream<rust_types.RustDartReadRequest> get onDartReadRequest;

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);

  void setVolume(double volume);
  void setRate(double rate);
  void setPitch(double pitch);
  void setBufferSize(int frames);

  void setEqualizer(Equalizer equalizer);
  void setEqualizerBand(int band, double gainDb);
  void setSilenceSkip(SilenceSkipConfig config);
  void setVisualizerEnabled(bool enabled);
  void setReplayGain(ReplayGainConfig config);
  void setPreamp(double preampDb);
  void setBalance(double balance);
  void setMono(bool enabled);
  void setCrossfeed(CrossfeedMode mode);
  void setSpatializer({required bool enabled, required double width});
  void setReverb({
    required bool enabled,
    required double roomSize,
    required double damping,
    required double width,
    required double wet,
    required double dry,
  });
  void setLimiterEnabled(bool enabled);

  void setSpatialEnabled(bool enabled);
  void setSpatialListener(SpatialListener listener);
  void setSpatialEmitter(SpatialEmitter emitter);
  void setSpatialDopplerFactor(double factor);
  void setSpatialSpeedOfSound(double speed);

  Future<void> setDevice(String deviceId);
  AudioDevice getCurrentDevice();
  void setPauseOnDeviceChange(bool enabled);
  bool getPauseOnDeviceChange();

  Future<void> dispose();
}

/// Platform-level audio device enumeration, offline acoustic analysis, and logging service.
abstract class PlatformService {
  Future<List<AudioDevice>> getAudioDevices();
  Stream<List<AudioDevice>> getAudioDevicesStream();
  List<AudioDevice> getAudioDevicesSync();
  Future<List<AudioDevice>> getCaptureDevices();
  List<AudioDevice> getCaptureDevicesSync();

  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  });

  void setLogLevel(int level);
}

/// Private deterministic mapper between Rust bridge models and Dart domain models.
abstract final class _RustModelMapper {
  static AudioDevice toAudioDevice(rust_types.RustAudioDevice dev) {
    final isAuto = dev.isAuto || dev.id == 'auto' || dev.id.isEmpty;
    return AudioDevice(
      id: isAuto ? 'auto' : dev.id,
      effectiveId: dev.effectiveId,
      name: isAuto ? 'SYSTEM DEFAULT' : dev.name,
      resolvedName: isAuto && dev.name.isNotEmpty ? dev.name : null,
      isAuto: isAuto,
    );
  }

  static List<AudioDevice> toAudioDeviceList(
    Iterable<rust_types.RustAudioDevice> list,
  ) {
    return <AudioDevice>[AudioDevice.auto, ...list.map(toAudioDevice)];
  }

  static PlaybackState toPlaybackState(int stateCode) {
    return switch (stateCode) {
      1 => PlaybackState.playing,
      2 => PlaybackState.paused,
      3 => PlaybackState.completed,
      4 => PlaybackState.buffering,
      5 => PlaybackState.error,
      6 => PlaybackState.opening,
      _ => PlaybackState.stopped,
    };
  }

  static BufferedRange toBufferedRange(rust_types.RustBufferedRange telemetry) {
    return BufferedRange(
      start: Duration(milliseconds: telemetry.startMs.toInt()),
      end: Duration(milliseconds: telemetry.endMs.toInt()),
      duration: Duration(milliseconds: telemetry.durationMs.toInt()),
      fillPercentage: telemetry.fillPercentage,
      percentage: telemetry.streamPercentage,
      isBuffering: telemetry.isBuffering,
      isEof: telemetry.isEof,
    );
  }

  static AudioAnalysisResult toAnalysisResult(
    rust_types.RustAudioAnalysisResult res,
  ) {
    final rg = res.integratedLufs != 0.0
        ? ReplayGainResult(
            gainDb: res.replayGainDb,
            peak: res.peakAmplitude,
            lufs: res.integratedLufs,
          )
        : null;
    final wf = res.waveformPeaks.isNotEmpty
        ? WaveformResult(points: res.waveformPeaks.toList())
        : null;
    return AudioAnalysisResult(
      duration: Duration(milliseconds: res.durationMs.toInt()),
      sampleRate: res.sampleRate,
      channels: res.channels,
      bitrate: res.sampleRate * res.channels * 16,
      peak: res.peakAmplitude,
      replayGain: rg,
      waveform: wf,
    );
  }
}

/// Shared `flutter_rust_bridge` implementation of [PlayerBackend] used across Native and Web.
abstract class RustBridgePlayerBackend implements PlayerBackend {
  rust.RustPlayer? _rustPlayer;
  PlayerBackendListener? _listener;
  StreamSubscription<rust_types.RustPlayerEvent>? _eventSub;
  final StreamController<rust_types.RustDartReadRequest>
      _dartReadRequestController =
      StreamController<rust_types.RustDartReadRequest>.broadcast();
  bool _isDisposed = false;

  int _initSampleRate = 48000;
  int _initChannels = 2;
  int _initPeriodSize = 2048;
  String? _initDeviceId;
  Future<void>? _playerInitFuture;
  int _lastDurationMs = 0;
  int _lastBitrate = 0;

  // Pending DSP and configuration snapshots applied once RustPlayer is ready
  double _pendingVolume = 1.0;
  double _pendingRate = 1.0;
  double _pendingPitch = 1.0;
  Equalizer _pendingEqualizer = Equalizer.flat;
  SilenceSkipConfig _pendingSilenceConfig = const SilenceSkipConfig();
  bool _pendingVisualizerEnabled = false;
  double _pendingPreamp = 0.0;
  ReplayGainConfig _pendingReplayGain = const ReplayGainConfig();
  double _pendingBalance = 0.0;
  bool _pendingMono = false;
  CrossfeedMode _pendingCrossfeed = CrossfeedMode.off;
  bool _pendingSpatializerEnabled = false;
  double _pendingSpatializerWidth = 1.0;
  Reverb _pendingReverb = Reverb.off;
  bool _pendingLimiterEnabled = true;
  bool _pendingPauseOnDeviceChange = false;
  bool _pendingSpatialEnabled = false;
  SpatialListener? _pendingSpatialListener;
  SpatialEmitter? _pendingSpatialEmitter;
  double? _pendingSpatialDoppler;
  double? _pendingSpatialSpeedOfSound;

  /// Ensures the underlying `flutter_rust_bridge` runtime is initialized on the current platform.
  Future<void> ensureRuntimeInitialized();

  @override
  Stream<rust_types.RustDartReadRequest> get onDartReadRequest =>
      _dartReadRequestController.stream;

  @override
  int get sampleRate {
    if (_isDisposed || _rustPlayer == null) return _initSampleRate;
    final sr = _rustPlayer!.getSampleRate();
    return sr > 0 ? sr : _initSampleRate;
  }

  @override
  int get channels {
    if (_isDisposed || _rustPlayer == null) return _initChannels;
    final ch = _rustPlayer!.getChannels();
    return ch > 0 ? ch : _initChannels;
  }

  @override
  int get pinnedHeadSize {
    if (_isDisposed || _rustPlayer == null) return 0;
    return _rustPlayer!.getPinnedHeadSize().toInt();
  }

  @override
  Uint8List? getMetaBytes() {
    if (_isDisposed || _rustPlayer == null) return null;
    return _rustPlayer!.getMetaBytes();
  }

  @override
  void setListener(PlayerBackendListener listener) {
    _listener = listener;
  }

  @override
  void init({
    int sampleRate = 48000,
    int channels = 2,
    int periodSize = 2048,
    String? playbackDeviceId,
  }) {
    _initSampleRate = sampleRate > 0 ? sampleRate : 48000;
    _initChannels = channels > 0 ? channels : 2;
    _initPeriodSize = periodSize > 0 ? periodSize : 2048;
    _initDeviceId = (playbackDeviceId != null &&
            playbackDeviceId.isNotEmpty &&
            playbackDeviceId != 'auto')
        ? playbackDeviceId
        : null;
    _playerInitFuture = _ensurePlayerCreated();
  }

  Future<void> _ensurePlayerCreated() async {
    if (_isDisposed || _rustPlayer != null) return;
    await ensureRuntimeInitialized();
    if (_isDisposed || _rustPlayer != null) return;

    final player = rust.RustPlayer(
      sampleRate: _initSampleRate,
      channels: _initChannels,
      periodSize: _initPeriodSize,
      playbackDeviceId: _initDeviceId,
    );
    if (_isDisposed) {
      try {
        player.dispose();
      } catch (_) {}
      return;
    }
    _rustPlayer = player;
    _eventSub = player.subscribeEvents().listen(_dispatchRustEvent);
    _applyPendingConfiguration(player);
  }

  void _applyPendingConfiguration(rust.RustPlayer player) {
    if (_pendingVolume != 1.0) player.setVolume(volume: _pendingVolume);
    if (_pendingRate != 1.0) player.setRate(rate: _pendingRate);
    if (_pendingPitch != 1.0) player.setPitch(pitch: _pendingPitch);
    if (_pendingEqualizer != Equalizer.flat) {
      player.setEqualizer(
        params: rust_types.RustEqualizerParams(
          gains: Float32List.fromList(_pendingEqualizer.toList()),
          enabled: true,
        ),
      );
    }
    if (_pendingSilenceConfig.mode != SilenceSkipMode.disabled) {
      player.setSilenceConfig(
        config: rust_types.RustSilenceConfig(
          mode: _pendingSilenceConfig.mode.value,
          thresholdDb: _pendingSilenceConfig.thresholdDb,
          minSilenceDurationMs:
              _pendingSilenceConfig.minSilenceDuration.inMilliseconds,
          paddingMs: _pendingSilenceConfig.padding.inMilliseconds,
          enabled: true,
        ),
      );
    }
    if (_pendingVisualizerEnabled) {
      player.setVisualizerEnabled(enabled: true);
    }
    if (_pendingPreamp != 0.0) {
      player.setPreamp(preampDb: _pendingPreamp);
    }
    if (_pendingReplayGain.enabled) {
      player.setReplayGain(
        gainDb: _pendingReplayGain.gainDb,
        peak: _pendingReplayGain.peak > 0.0 ? _pendingReplayGain.peak : 1.0,
        preventClipping: _pendingReplayGain.preventClipping,
      );
    }
    if (_pendingBalance != 0.0) {
      player.setBalance(pan: _pendingBalance);
    }
    if (_pendingMono) {
      player.setMono(enabled: true);
    }
    if (_pendingCrossfeed != CrossfeedMode.off) {
      player.setCrossfeed(mode: _pendingCrossfeed.index);
    }
    if (_pendingSpatializerEnabled) {
      player.setSpatializer(
        enabled: true,
        width: _pendingSpatializerWidth,
      );
    }
    if (_pendingReverb.enabled) {
      player.setReverb(
        params: rust_types.RustReverbParams(
          roomSize: _pendingReverb.roomSize,
          damping: _pendingReverb.damping,
          wet: _pendingReverb.wet,
          dry: _pendingReverb.dry,
          width: _pendingReverb.width,
          mode: 0.0,
          enabled: true,
        ),
      );
    }
    if (!_pendingLimiterEnabled) {
      player.setLimiter(enabled: false);
    }
    if (_pendingPauseOnDeviceChange) {
      player.setPauseOnDeviceChange(enabled: true);
    }
    if (_pendingSpatialEnabled) {
      player.setSpatialEnabled(enabled: true);
    }
    if (_pendingSpatialListener != null) {
      player.setSpatialListener(listener: _pendingSpatialListener!.toRust());
    }
    if (_pendingSpatialEmitter != null) {
      player.setSpatialEmitter(emitter: _pendingSpatialEmitter!.toRust());
    }
    if (_pendingSpatialDoppler != null) {
      player.setSpatialDopplerFactor(factor: _pendingSpatialDoppler!);
    }
    if (_pendingSpatialSpeedOfSound != null) {
      player.setSpatialSpeedOfSound(speed: _pendingSpatialSpeedOfSound!);
    }
  }

  /// Optional hook for native backends to read the leading magic bytes of a local file.
  Uint8List? readLocalHeaderBytes(String source) => null;

  void _dispatchRustEvent(rust_types.RustPlayerEvent event) {
    if (_isDisposed) return;
    if (event is rust_types.RustPlayerEvent_DartReadRequest) {
      if (!_dartReadRequestController.isClosed) {
        _dartReadRequestController.add(event.field0);
      }
      return;
    }

    final l = _listener;
    if (l == null) return;

    event.when(
      state: (s) => l.onState(_RustModelMapper.toPlaybackState(s)),
      position: (posMs) => l.onPosition(Duration(milliseconds: posMs.toInt())),
      duration: (durMs) {
        final ms = durMs.toInt();
        _lastDurationMs = ms;
        l.onDuration(Duration(milliseconds: ms));
      },
      isPlaying: l.onPlaying,
      isBuffering: l.onBuffering,
      isCompleted: l.onCompleted,
      volume: (_) {},
      rate: (_) {},
      pitch: (_) {},
      bitrate: (b) {
        _lastBitrate = b;
        l.onBitrate(b);
      },
      bufferSize: (_) {},
      device: (dev) => l.onDevice(_RustModelMapper.toAudioDevice(dev)),
      visualizer: (vis) => l.onVisualizer(
        VisualizerData(
          bands: vis.bands.toList(),
          rms: vis.rms,
          peak: vis.peak,
          left: vis.left,
          right: vis.right,
        ),
      ),
      visualizerEnabled: (_) {},
      bufferedRange: (br) =>
          l.onBufferedRange(_RustModelMapper.toBufferedRange(br)),
      silenceConfig: (_) {},
      silenceSaved: (savedMs) =>
          l.onSilenceSaved(Duration(milliseconds: savedMs.toInt())),
      equalizer: (_) {},
      preamp: (_) {},
      replayGain: (_) {},
      balance: (_) {},
      mono: (_) {},
      crossfeed: (_) {},
      spatializer: (_, __) {},
      reverb: (_) {},
      limiter: (_) {},
      dartReadRequest: (req) {
        if (!_dartReadRequestController.isClosed) {
          _dartReadRequestController.add(req);
        }
      },
      error: l.onError,
    );
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw const MiniaudioPlayerException(
        'Player is already disposed',
        errorCode: MapResult.errorInvalidState,
      );
    }
  }

  Future<rust.RustPlayer> _requireInitializedPlayer() async {
    _ensureNotDisposed();
    await (_playerInitFuture ??= _ensurePlayerCreated());
    _ensureNotDisposed();
    return _rustPlayer!;
  }

  void _syncInitialSourceTelemetry(
    String sourceHint, {
    Uint8List? headerBytes,
    int? knownTotalBytes,
  }) {
    final player = _rustPlayer;
    final l = _listener;
    if (player == null || l == null) return;

    final rawDurMs = player.getDurationMs().toInt();
    final durMs = rawDurMs > 0 ? rawDurMs : _lastDurationMs;
    final rawBitrate = player.getBitrate();
    final bitrate = rawBitrate > 0 ? rawBitrate : _lastBitrate;
    final br = player.getBufferedRange();

    if (durMs > 0) {
      l.onDuration(Duration(milliseconds: durMs));
    }
    if (bitrate > 0) {
      l.onBitrate(bitrate);
    }
    l.onBufferedRange(_RustModelMapper.toBufferedRange(br));

    final metaBytes = headerBytes ?? player.getMetaBytes();
    final metadata = AudioTrackMetadata.resolve(
      sourceHint: sourceHint,
      durationMs: durMs,
      bitrate: bitrate,
      sampleRate: sampleRate,
      channels: channels,
      audioDataOffset: player.getAudioDataOffset().toInt(),
      headerBytes: metaBytes,
      knownTotalBytes: knownTotalBytes,
    );
    l.onTrackMetadata(metadata);
  }

  @override
  Future<void> openSource(String source, {Map<String, String>? headers}) async {
    final player = await _requireInitializedPlayer();
    final headerList = headers?.entries
        .map((e) => rust_types.RustHttpHeader(key: e.key, value: e.value))
        .toList();

    try {
      await player.openSource(source: source, headers: headerList);
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Failed to open source',
        defaultErrorCode: MapResult.errorFileNotFound,
      );
    }

    _syncInitialSourceTelemetry(
      source,
      headerBytes: readLocalHeaderBytes(source),
    );
  }

  @override
  Future<void> openMemory(Uint8List bytes) async {
    final player = await _requireInitializedPlayer();
    try {
      await player.openMemory(data: bytes);
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Failed to decode memory source',
        defaultErrorCode: MapResult.errorDecodeFailed,
      );
    }

    _syncInitialSourceTelemetry(
      'memory://buffer',
      headerBytes: bytes,
      knownTotalBytes: bytes.length,
    );
  }

  @override
  Future<void> openCustomStream({
    required int streamId,
    int? totalSize,
    required bool isSeekable,
    required Uint8List initialBytes,
  }) async {
    final player = await _requireInitializedPlayer();
    try {
      await player.openCustomStream(
        streamId: streamId,
        totalSize: totalSize != null ? BigInt.from(totalSize) : null,
        isSeekable: isSeekable,
        initialBytes: initialBytes,
      );
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Failed to open custom stream',
        defaultErrorCode: MapResult.errorDecodeFailed,
      );
    }

    _syncInitialSourceTelemetry(
      'custom://provider/$streamId',
      headerBytes: initialBytes,
      knownTotalBytes: totalSize,
    );
  }

  @override
  void supplyCustomBytes({
    required int streamId,
    required int requestId,
    required Uint8List data,
    required bool isEof,
  }) {
    if (_isDisposed || _rustPlayer == null) return;
    try {
      _rustPlayer!.supplyCustomBytes(
        streamId: streamId,
        requestId: BigInt.from(requestId),
        data: data,
        isEof: isEof,
      );
    } catch (_) {}
  }

  @override
  void notifyCustomError({
    required int streamId,
    required int requestId,
    required String errorMessage,
  }) {
    if (_isDisposed || _rustPlayer == null) return;
    try {
      _rustPlayer!.notifyCustomError(
        streamId: streamId,
        requestId: BigInt.from(requestId),
        errorMessage: errorMessage,
      );
    } catch (_) {}
  }

  @override
  Future<void> play() async {
    final player = await _requireInitializedPlayer();
    await player.play();
    if (_isDisposed) return;
    final playing = player.isPlaying();
    _listener?.onPlaying(playing);
    if (playing) {
      _listener?.onState(PlaybackState.playing);
    }
  }

  @override
  Future<void> pause() async {
    final player = await _requireInitializedPlayer();
    await player.pause();
    if (_isDisposed) return;
    final playing = player.isPlaying();
    _listener?.onPlaying(playing);
    if (!playing && !player.isCompleted()) {
      _listener?.onState(PlaybackState.paused);
    }
  }

  @override
  Future<void> stop() async {
    final player = await _requireInitializedPlayer();
    await player.stop();
    if (_isDisposed) return;
    _listener?.onPlaying(false);
    _listener?.onCompleted(false);
    _listener?.onState(PlaybackState.stopped);
    _listener?.onPosition(Duration.zero);
  }

  @override
  Future<void> seek(Duration position) async {
    final player = await _requireInitializedPlayer();
    final targetMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    await player.seek(positionMs: targetMs);
    if (_isDisposed) return;
    final durMs = player.getDurationMs().toInt();
    final clampedMs = durMs > 0 ? targetMs.clamp(0, durMs) : targetMs;
    _listener?.onPosition(Duration(milliseconds: clampedMs));
  }

  @override
  void setVolume(double volume) {
    _ensureNotDisposed();
    final clamped = volume.clamp(0.0, 2.0);
    _pendingVolume = clamped;
    _rustPlayer?.setVolume(volume: clamped);
  }

  @override
  void setRate(double rate) {
    _ensureNotDisposed();
    final clamped = rate.clamp(0.1, 4.0);
    _pendingRate = clamped;
    _rustPlayer?.setRate(rate: clamped);
  }

  @override
  void setPitch(double pitch) {
    _ensureNotDisposed();
    final clamped = pitch.clamp(0.5, 2.0);
    _pendingPitch = clamped;
    _rustPlayer?.setPitch(pitch: clamped);
  }

  @override
  void setBufferSize(int frames) {
    _ensureNotDisposed();
    final size = frames < 0 ? 0 : frames;
    _initPeriodSize = size > 0 ? size : 2048;
    _rustPlayer?.setBufferSize(frames: size);
  }

  @override
  void setEqualizer(Equalizer equalizer) {
    _ensureNotDisposed();
    _pendingEqualizer = equalizer;
    _rustPlayer?.setEqualizer(
      params: rust_types.RustEqualizerParams(
        gains: Float32List.fromList(equalizer.toList()),
        enabled: true,
      ),
    );
  }

  @override
  void setEqualizerBand(int band, double gainDb) {
    _ensureNotDisposed();
    _pendingEqualizer = _pendingEqualizer.withBand(band, gainDb);
    _rustPlayer?.setEqualizerBand(
      band: band,
      gainDb: Equalizer.clampGain(gainDb),
    );
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _ensureNotDisposed();
    final valid = config.validated();
    _pendingSilenceConfig = valid;
    _rustPlayer?.setSilenceConfig(
      config: rust_types.RustSilenceConfig(
        mode: valid.mode.value,
        thresholdDb: valid.thresholdDb,
        minSilenceDurationMs: valid.minSilenceDuration.inMilliseconds,
        paddingMs: valid.padding.inMilliseconds,
        enabled: valid.mode != SilenceSkipMode.disabled,
      ),
    );
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    _ensureNotDisposed();
    _pendingVisualizerEnabled = enabled;
    _rustPlayer?.setVisualizerEnabled(enabled: enabled);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    _ensureNotDisposed();
    _pendingReplayGain = config;
    final player = _rustPlayer;
    if (player == null) return;
    if (config.enabled) {
      player.setReplayGain(
        gainDb: config.gainDb,
        peak: config.peak > 0.0 ? config.peak : 1.0,
        preventClipping: config.preventClipping,
      );
    } else {
      player.clearReplayGain();
    }
  }

  @override
  void setPreamp(double preampDb) {
    _ensureNotDisposed();
    final clamped = preampDb.clamp(-24.0, 24.0);
    _pendingPreamp = clamped;
    _rustPlayer?.setPreamp(preampDb: clamped);
  }

  @override
  void setBalance(double balance) {
    _ensureNotDisposed();
    final clamped = balance.clamp(-1.0, 1.0);
    _pendingBalance = clamped;
    _rustPlayer?.setBalance(pan: clamped);
  }

  @override
  void setMono(bool enabled) {
    _ensureNotDisposed();
    _pendingMono = enabled;
    _rustPlayer?.setMono(enabled: enabled);
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _ensureNotDisposed();
    _pendingCrossfeed = mode;
    _rustPlayer?.setCrossfeed(mode: mode.index);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _ensureNotDisposed();
    final clampedWidth = width.clamp(1.0, 2.0);
    _pendingSpatializerEnabled = enabled;
    _pendingSpatializerWidth = clampedWidth;
    _rustPlayer?.setSpatializer(enabled: enabled, width: clampedWidth);
  }

  @override
  void setReverb({
    required bool enabled,
    required double roomSize,
    required double damping,
    required double width,
    required double wet,
    required double dry,
  }) {
    _ensureNotDisposed();
    final rev = Reverb(
      enabled: enabled,
      roomSize: roomSize,
      damping: damping,
      width: width,
      wet: wet,
      dry: dry,
    ).validated();
    _pendingReverb = rev;
    _rustPlayer?.setReverb(
      params: rust_types.RustReverbParams(
        roomSize: rev.roomSize,
        damping: rev.damping,
        wet: rev.wet,
        dry: rev.dry,
        width: rev.width,
        mode: 0.0,
        enabled: rev.enabled,
      ),
    );
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _ensureNotDisposed();
    _pendingLimiterEnabled = enabled;
    _rustPlayer?.setLimiter(enabled: enabled);
  }

  @override
  void setSpatialEnabled(bool enabled) {
    _ensureNotDisposed();
    _pendingSpatialEnabled = enabled;
    _rustPlayer?.setSpatialEnabled(enabled: enabled);
  }

  @override
  void setSpatialListener(SpatialListener listener) {
    _ensureNotDisposed();
    _pendingSpatialListener = listener;
    _rustPlayer?.setSpatialListener(listener: listener.toRust());
  }

  @override
  void setSpatialEmitter(SpatialEmitter emitter) {
    _ensureNotDisposed();
    _pendingSpatialEmitter = emitter;
    _rustPlayer?.setSpatialEmitter(emitter: emitter.toRust());
  }

  @override
  void setSpatialDopplerFactor(double factor) {
    _ensureNotDisposed();
    _pendingSpatialDoppler = factor;
    _rustPlayer?.setSpatialDopplerFactor(factor: factor);
  }

  @override
  void setSpatialSpeedOfSound(double speed) {
    _ensureNotDisposed();
    _pendingSpatialSpeedOfSound = speed;
    _rustPlayer?.setSpatialSpeedOfSound(speed: speed);
  }

  @override
  Future<void> setDevice(String deviceId) async {
    final player = await _requireInitializedPlayer();
    final normalizedId =
        (deviceId.isEmpty || deviceId == 'auto') ? '' : deviceId;
    try {
      await player.setDevice(deviceId: normalizedId);
      if (!_isDisposed) {
        _listener?.onDevice(getCurrentDevice());
      }
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Failed to switch audio device',
        defaultErrorCode: MapResult.errorEngineInit,
      );
    }
  }

  @override
  AudioDevice getCurrentDevice() {
    if (_isDisposed || _rustPlayer == null) return AudioDevice.auto;
    try {
      final dev = _rustPlayer!.getCurrentDevice();
      return _RustModelMapper.toAudioDevice(dev);
    } catch (_) {
      return AudioDevice.auto;
    }
  }

  @override
  void setPauseOnDeviceChange(bool enabled) {
    _ensureNotDisposed();
    _pendingPauseOnDeviceChange = enabled;
    _rustPlayer?.setPauseOnDeviceChange(enabled: enabled);
  }

  @override
  bool getPauseOnDeviceChange() {
    if (_isDisposed || _rustPlayer == null) return _pendingPauseOnDeviceChange;
    return _rustPlayer!.getPauseOnDeviceChange();
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    final player = _rustPlayer;
    _rustPlayer = null;
    if (player != null) {
      try {
        player.dispose();
      } catch (_) {}
    }
    final sub = _eventSub;
    _eventSub = null;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    unawaited(_dartReadRequestController.close());
  }
}

/// Shared `flutter_rust_bridge` implementation of [PlatformService] used across Native and Web.
abstract class RustBridgePlatformService implements PlatformService {
  /// Ensures the underlying `flutter_rust_bridge` runtime is initialized on the current platform.
  Future<void> ensureRuntimeInitialized();

  /// Normalizes a local path or `file://` URI for the current platform.
  String normalizeLocalPath(String rawPath) => rawPath.trim();

  @override
  Future<List<AudioDevice>> getAudioDevices() async {
    await ensureRuntimeInitialized();
    final list = await rust.getAudioDevices();
    return _RustModelMapper.toAudioDeviceList(list);
  }

  @override
  List<AudioDevice> getAudioDevicesSync() {
    if (!RustLib.instance.initialized) return [AudioDevice.auto];
    try {
      final list = rust.getAudioDevicesSync();
      return _RustModelMapper.toAudioDeviceList(list);
    } catch (_) {
      return [AudioDevice.auto];
    }
  }

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() =>
      _pollAudioDevices().asBroadcastStream(
        onCancel: (subscription) => subscription.cancel(),
      );

  Stream<List<AudioDevice>> _pollAudioDevices() async* {
    List<AudioDevice>? previous;
    while (true) {
      final current = await getAudioDevices();
      if (previous == null || !_deviceListsEqual(previous, current)) {
        previous = current;
        yield current;
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
  }

  bool _deviceListsEqual(List<AudioDevice> a, List<AudioDevice> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].effectiveId != b[i].effectiveId) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<List<AudioDevice>> getCaptureDevices() async {
    await ensureRuntimeInitialized();
    final list = await rust.getCaptureDevices();
    return _RustModelMapper.toAudioDeviceList(list);
  }

  @override
  List<AudioDevice> getCaptureDevicesSync() {
    if (!RustLib.instance.initialized) return [AudioDevice.auto];
    try {
      final list = rust.getCaptureDevicesSync();
      return _RustModelMapper.toAudioDeviceList(list);
    } catch (_) {
      return [AudioDevice.auto];
    }
  }

  @override
  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    MapLogger.info('analyzeAudio() -> $filePath');
    await ensureRuntimeInitialized();
    try {
      final res = await rust.analyzeAudioFile(
        path: normalizeLocalPath(filePath),
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      final result = _RustModelMapper.toAnalysisResult(res);
      MapLogger.info(
        'analyzeAudio() completed -> duration: ${result.duration.inMilliseconds}ms, '
        'peak: ${result.peak.toStringAsFixed(4)}, lufs: ${result.replayGain?.lufs.toStringAsFixed(2)}',
      );
      return result;
    } catch (e) {
      MapLogger.error('analyzeAudio() failed for $filePath: $e');
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Analysis failed',
      );
    }
  }

  @override
  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    MapLogger.info('analyzeAudioSync() -> $filePath');
    try {
      final res = rust.analyzeAudioFileSync(
        path: normalizeLocalPath(filePath),
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      final result = _RustModelMapper.toAnalysisResult(res);
      MapLogger.info(
        'analyzeAudioSync() completed -> duration: ${result.duration.inMilliseconds}ms, '
        'peak: ${result.peak.toStringAsFixed(4)}, lufs: ${result.replayGain?.lufs.toStringAsFixed(2)}',
      );
      return result;
    } catch (e) {
      MapLogger.error('analyzeAudioSync() failed for $filePath: $e');
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Analysis failed',
      );
    }
  }

  @override
  Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    MapLogger.info('analyzeAudioMemory() -> ${bytes.length} bytes');
    await ensureRuntimeInitialized();
    try {
      final res = await rust.analyzeAudioMemory(
        data: bytes,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      final result = _RustModelMapper.toAnalysisResult(res);
      MapLogger.info(
        'analyzeAudioMemory() completed -> duration: ${result.duration.inMilliseconds}ms, '
        'peak: ${result.peak.toStringAsFixed(4)}, lufs: ${result.replayGain?.lufs.toStringAsFixed(2)}',
      );
      return result;
    } catch (e) {
      MapLogger.error('analyzeAudioMemory() failed: $e');
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Analysis failed',
      );
    }
  }

  @override
  void setLogLevel(int level) {
    MapLogger.debug('PlatformService setLogLevel -> $level');
    if (RustLib.instance.initialized) {
      try {
        rust.setLogLevel(level: level);
      } catch (_) {}
    } else {
      ensureRuntimeInitialized().then((_) {
        try {
          rust.setLogLevel(level: level);
        } catch (_) {}
      });
    }
  }
}
