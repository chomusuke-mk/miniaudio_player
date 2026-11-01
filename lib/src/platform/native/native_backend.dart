import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

import '../../api/audio_analysis_result.dart';
import '../../api/audio_device.dart';
import '../../api/buffered_range.dart';
import '../../api/dsp_config.dart';
import '../../api/player_exception.dart';
import '../../api/player_state.dart';
import '../../api/silence_skip_config.dart';
import '../../api/spatial.dart';
import '../../api/track_metadata.dart';
import '../../api/visualizer_data.dart';
import '../../equalizer.dart';
import '../../reverb.dart';
import '../../rust/api/player.dart' as rust;
import '../../rust/api/types.dart' as rust_types;
import '../../rust/frb_generated.dart';
import '../platform_backend.dart';

/// Deterministic mapper between Rust FFI models and Dart domain models.
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

/// Locates and initializes the native Rust FFI shared library across runtime and test environments.
abstract final class _NativeLibraryLoader {
  static Future<void>? _initFuture;

  static Future<void> ensureInitialized() async {
    if (RustLib.instance.initialized) return;
    await (_initFuture ??= _initializeRustLib());
  }

  static Future<void> _initializeRustLib() async {
    try {
      await RustLib.init();
      return;
    } catch (_) {
      final candidatePath = _findLocalSharedLibrary();
      if (candidatePath != null) {
        await RustLib.init(
          externalLibrary: ExternalLibrary.open(candidatePath),
        );
        return;
      }
      rethrow;
    }
  }

  static String? _findLocalSharedLibrary() {
    final libName = _platformLibraryName();
    final cwd = Directory.current.path;

    final hooksDir = Directory(
      '$cwd/.dart_tool/hooks_runner/shared/miniaudio_player/build',
    );
    if (hooksDir.existsSync()) {
      for (final entry in hooksDir.listSync().whereType<Directory>()) {
        final candidate = File('${entry.path}/$libName');
        if (candidate.existsSync()) return candidate.path;
      }
    }

    final targetCandidates = <String>[
      '$cwd/rust/target/release/$libName',
      '$cwd/rust/target/debug/$libName',
      '$cwd/../rust/target/release/$libName',
      '$cwd/../rust/target/debug/$libName',
    ];
    for (final path in targetCandidates) {
      if (File(path).existsSync()) return path;
    }
    return null;
  }

  static String _platformLibraryName() {
    if (Platform.isWindows) return 'miniaudio_player.dll';
    if (Platform.isMacOS || Platform.isIOS) return 'libminiaudio_player.dylib';
    return 'libminiaudio_player.so';
  }
}

/// Native FFI implementation of [PlayerBackend] backed by `RustPlayer`.
class NativePlayerBackend implements PlayerBackend {
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

  NativePlayerBackend([dynamic _]);

  static Future<void> ensureRustInitialized() =>
      _NativeLibraryLoader.ensureInitialized();

  @override
  Stream<rust_types.RustDartReadRequest> get onDartReadRequest =>
      _dartReadRequestController.stream;

  @override
  dynamic get handle => _rustPlayer;

  @override
  int get sampleRate {
    if (_isDisposed) return 0;
    final sr = _rustPlayer?.getSampleRate() ?? 0;
    return sr > 0 ? sr : _initSampleRate;
  }

  @override
  int get channels {
    if (_isDisposed) return 0;
    final ch = _rustPlayer?.getChannels() ?? 0;
    return ch > 0 ? ch : _initChannels;
  }

  @override
  int get pinnedHeadSize {
    if (_isDisposed) return 0;
    return _rustPlayer?.getPinnedHeadSize().toInt() ?? 0;
  }

  @override
  Uint8List? getMetaBytes() {
    if (_isDisposed) return null;
    final bytes = _rustPlayer?.getMetaBytes();
    return (bytes != null && bytes.isNotEmpty) ? bytes : null;
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
    _initDeviceId = playbackDeviceId;

    if (RustLib.instance.initialized) {
      _ensurePlayerCreated();
    } else {
      ensureRustInitialized().then((_) {
        if (!_isDisposed) _ensurePlayerCreated();
      });
    }
  }

  void _ensurePlayerCreated() {
    if (_rustPlayer != null || _isDisposed) return;
    final player = rust.RustPlayer(
      sampleRate: _initSampleRate,
      channels: _initChannels,
      periodSize: _initPeriodSize,
      playbackDeviceId: _initDeviceId,
    );
    _rustPlayer = player;
    _eventSub = player.subscribeEvents().listen(_handleRustEvent);
  }

  void _handleRustEvent(rust_types.RustPlayerEvent event) {
    if (_isDisposed) return;
    final l = _listener;
    if (l == null) return;

    switch (event) {
      case rust_types.RustPlayerEvent_State(field0: final s):
        l.onState(_RustModelMapper.toPlaybackState(s));
      case rust_types.RustPlayerEvent_Position(field0: final p):
        l.onPosition(Duration(milliseconds: p.toInt()));
      case rust_types.RustPlayerEvent_Duration(field0: final d):
        l.onDuration(Duration(milliseconds: d.toInt()));
      case rust_types.RustPlayerEvent_IsPlaying(field0: final p):
        l.onPlaying(p);
      case rust_types.RustPlayerEvent_IsBuffering(field0: final b):
        l.onBuffering(b);
      case rust_types.RustPlayerEvent_IsCompleted(field0: final c):
        l.onCompleted(c);
      case rust_types.RustPlayerEvent_Volume(field0: final v):
        l.onVolume(v);
      case rust_types.RustPlayerEvent_Rate(field0: final r):
        l.onRate(r);
      case rust_types.RustPlayerEvent_Pitch(field0: final p):
        l.onPitch(p);
      case rust_types.RustPlayerEvent_Bitrate(field0: final b):
        l.onBitrate(b);
      case rust_types.RustPlayerEvent_BufferSize(field0: final sz):
        l.onBufferSize(sz);
      case rust_types.RustPlayerEvent_SilenceConfig(field0: final sc):
        l.onSilenceConfig(
          SilenceSkipConfig.fromRaw(
            mode: sc.mode,
            thresholdDb: sc.thresholdDb,
            minSilenceDurationMs: sc.minSilenceDurationMs,
            paddingMs: sc.paddingMs,
          ),
        );
      case rust_types.RustPlayerEvent_SilenceSaved(field0: final ms):
        l.onSilenceSaved(Duration(milliseconds: ms.toInt()));
      case rust_types.RustPlayerEvent_BufferedRange(field0: final br):
        l.onBufferedRange(_RustModelMapper.toBufferedRange(br));
      case rust_types.RustPlayerEvent_Visualizer(field0: final vz):
        l.onVisualizer(
          VisualizerData(
            bands: vz.bands.toList(),
            rms: vz.rms,
            peak: vz.peak,
            left: vz.left,
            right: vz.right,
          ),
        );
      case rust_types.RustPlayerEvent_VisualizerEnabled(field0: final en):
        l.onVisualizerEnabled(en);
      case rust_types.RustPlayerEvent_Device(field0: final d):
        l.onDevice(_RustModelMapper.toAudioDevice(d));
      case rust_types.RustPlayerEvent_Equalizer(field0: final eq):
        l.onEqualizer(Equalizer.fromList(eq.gains.toList()));
      case rust_types.RustPlayerEvent_Preamp(field0: final p):
        l.onPreamp(p);
      case rust_types.RustPlayerEvent_ReplayGain(field0: final rg):
        l.onReplayGain(
          ReplayGainConfig(
            gainDb: rg.gainDb,
            peak: rg.peak,
            preventClipping: rg.preventClipping,
            enabled: rg.enabled,
          ),
        );
      case rust_types.RustPlayerEvent_Balance(field0: final b):
        l.onBalance(b);
      case rust_types.RustPlayerEvent_Mono(field0: final m):
        l.onMono(m);
      case rust_types.RustPlayerEvent_Crossfeed(field0: final c):
        final mode = c >= 0 && c < CrossfeedMode.values.length
            ? CrossfeedMode.values[c]
            : CrossfeedMode.off;
        l.onCrossfeed(mode);
      case rust_types.RustPlayerEvent_Spatializer(
          enabled: final en,
          width: final w,
        ):
        l.onSpatializer(enabled: en, width: w);
      case rust_types.RustPlayerEvent_Reverb(field0: final rv):
        l.onReverb(
          Reverb(
            enabled: rv.enabled,
            roomSize: rv.roomSize,
            damping: rv.damping,
            width: rv.width,
            wet: rv.wet,
            dry: rv.dry,
          ),
        );
      case rust_types.RustPlayerEvent_Limiter(field0: final en):
        l.onLimiter(en);
      case rust_types.RustPlayerEvent_Error(
          message: final msg,
          code: final cd,
        ):
        l.onError(msg, cd);
      case rust_types.RustPlayerEvent_DartReadRequest(field0: final req):
        if (!_dartReadRequestController.isClosed) {
          _dartReadRequestController.add(req);
        }
    }
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
    await ensureRustInitialized();
    _ensureNotDisposed();
    _ensurePlayerCreated();
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

    final durMs = player.getDurationMs().toInt();
    final bitrate = player.getBitrate();
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
  Future<void> beginOpen() async {
    final player = await _requireInitializedPlayer();
    await player.beginOpen();
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
      );
    }
    _syncInitialSourceTelemetry(source);
  }

  @override
  Future<void> openMemory(Uint8List bytes) async {
    final player = await _requireInitializedPlayer();
    try {
      await player.openMemory(data: bytes);
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Failed to open memory buffer',
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
      );
    }
    _syncInitialSourceTelemetry(
      'custom://$streamId',
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
    _rustPlayer!.supplyCustomBytes(
      streamId: streamId,
      requestId: BigInt.from(requestId),
      data: data,
      isEof: isEof,
    );
  }

  @override
  void notifyCustomError({
    required int streamId,
    required int requestId,
    required String errorMessage,
  }) {
    if (_isDisposed || _rustPlayer == null) return;
    _rustPlayer!.notifyCustomError(
      streamId: streamId,
      requestId: BigInt.from(requestId),
      errorMessage: errorMessage,
    );
  }

  @override
  void notifyOpenError(int errorCode) {
    if (_isDisposed) return;
    final code = errorCode < 0 ? errorCode : MapResult.errorDecodeFailed;
    if (_rustPlayer != null) {
      _rustPlayer!.notifyOpenError(errorCode: code);
    } else {
      _listener?.onState(PlaybackState.error);
      _listener?.onError('Failed to open source', code);
    }
  }

  @override
  Future<void> play() async {
    final player = await _requireInitializedPlayer();
    try {
      await player.play();
      _listener?.onPlaying(true);
      _listener?.onState(PlaybackState.playing);
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(e, prefix: 'Play failed');
    }
  }

  @override
  Future<void> pause() async {
    _ensureNotDisposed();
    final player = _rustPlayer;
    if (player == null) return;
    await player.pause();
    _listener?.onPlaying(false);
    _listener?.onState(PlaybackState.paused);
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    final player = _rustPlayer;
    if (player == null) return;
    await player.stop();
    _listener?.onPlaying(false);
    _listener?.onPosition(Duration.zero);
    _listener?.onState(PlaybackState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    final player = await _requireInitializedPlayer();
    final targetMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    try {
      await player.seek(positionMs: targetMs);
      final status = player.getPlayerStatus();
      final actualMs = status.positionMs.toInt();
      _listener?.onPosition(
        Duration(milliseconds: actualMs >= 0 ? actualMs : targetMs),
      );
      if (status.state == 2) {
        _listener?.onCompleted(false);
        _listener?.onState(PlaybackState.paused);
      }
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(e, prefix: 'Seek failed');
    }
  }

  @override
  void setVolume(double volume) {
    _ensureNotDisposed();
    final clamped = volume.clamp(0.0, 2.0);
    _rustPlayer?.setVolume(volume: clamped);
    _listener?.onVolume(clamped);
  }

  @override
  void setRate(double rate) {
    _ensureNotDisposed();
    final clamped = rate.clamp(0.1, 4.0);
    _rustPlayer?.setRate(rate: clamped);
    _listener?.onRate(clamped);
  }

  @override
  void setPitch(double pitch) {
    _ensureNotDisposed();
    final clamped = pitch.clamp(0.5, 2.0);
    _rustPlayer?.setPitch(pitch: clamped);
    _listener?.onPitch(clamped);
  }

  @override
  void setBufferSize(int frames) {
    _ensureNotDisposed();
    final size = frames < 0 ? 0 : frames;
    _initPeriodSize = size > 0 ? size : 2048;
    _rustPlayer?.setBufferSize(frames: size);
    _listener?.onBufferSize(size);
  }

  @override
  void setEqualizer(Equalizer equalizer) {
    _ensureNotDisposed();
    final bands = Float32List.fromList(equalizer.toList());
    _rustPlayer?.setEqualizer(
      params: rust_types.RustEqualizerParams(gains: bands, enabled: true),
    );
    _listener?.onEqualizer(equalizer);
  }

  @override
  void setEqualizerBand(int band, double gainDb) {
    _ensureNotDisposed();
    if (band < 0 || band >= 10) {
      throw RangeError.range(band, 0, 9, 'band');
    }
    final clamped = Equalizer.clampGain(gainDb);
    _rustPlayer?.setEqualizerBand(band: band, gainDb: clamped);
    if (_rustPlayer != null) {
      final params = _rustPlayer!.getEqualizer();
      _listener?.onEqualizer(Equalizer.fromList(params.gains.toList()));
    }
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _ensureNotDisposed();
    final valid = config.validated();
    _rustPlayer?.setSilenceConfig(
      config: rust_types.RustSilenceConfig(
        mode: valid.mode.value,
        thresholdDb: valid.thresholdDb,
        minSilenceDurationMs: valid.minSilenceDuration.inMilliseconds,
        paddingMs: valid.padding.inMilliseconds,
        enabled: valid.mode != SilenceSkipMode.disabled,
      ),
    );
    _listener?.onSilenceConfig(valid);
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setVisualizerEnabled(enabled: enabled);
    _listener?.onVisualizerEnabled(enabled);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    _ensureNotDisposed();
    final effectiveGain = config.enabled ? config.gainDb : 0.0;
    final effectivePeak = config.peak > 0.0 ? config.peak : 1.0;
    _rustPlayer?.setReplayGain(
      gainDb: effectiveGain,
      peak: effectivePeak,
      preventClipping: config.preventClipping,
    );
    _listener?.onReplayGain(config);
  }

  @override
  void setPreamp(double preampDb) {
    _ensureNotDisposed();
    final clamped = preampDb.clamp(-24.0, 24.0);
    _rustPlayer?.setPreamp(preampDb: clamped);
    _listener?.onPreamp(clamped);
  }

  @override
  void setBalance(double balance) {
    _ensureNotDisposed();
    final clamped = balance.clamp(-1.0, 1.0);
    _rustPlayer?.setBalance(pan: clamped);
    _listener?.onBalance(clamped);
  }

  @override
  void setMono(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setMono(enabled: enabled);
    _listener?.onMono(enabled);
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _ensureNotDisposed();
    _rustPlayer?.setCrossfeed(mode: mode.index);
    _listener?.onCrossfeed(mode);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _ensureNotDisposed();
    final clampedWidth = width.clamp(1.0, 2.0);
    _rustPlayer?.setSpatializer(enabled: enabled, width: clampedWidth);
    _listener?.onSpatializer(enabled: enabled, width: clampedWidth);
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
    _rustPlayer?.setReverb(
      params: rust_types.RustReverbParams(
        enabled: rev.enabled,
        roomSize: rev.roomSize,
        damping: rev.damping,
        width: rev.width,
        wet: rev.wet,
        dry: rev.dry,
        mode: 0.0,
      ),
    );
    _listener?.onReverb(rev);
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setLimiter(enabled: enabled);
    _listener?.onLimiter(enabled);
  }

  @override
  void setSpatialEnabled(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatialEnabled(enabled: enabled);
  }

  @override
  void setSpatialListener(SpatialListener listener) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatialListener(listener: listener.toRust());
  }

  @override
  void setSpatialEmitter(SpatialEmitter emitter) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatialEmitter(emitter: emitter.toRust());
  }

  @override
  void setSpatialDopplerFactor(double factor) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatialDopplerFactor(factor: factor);
  }

  @override
  void setSpatialSpeedOfSound(double speed) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatialSpeedOfSound(speed: speed);
  }

  @override
  void setIcyMeta(Uint8List data) {
    _ensureNotDisposed();
    if (data.isEmpty) return;
    _rustPlayer?.setIcyMeta(data: data);
  }

  @override
  void probeTail(Uint8List data, int tailOffset) {
    _ensureNotDisposed();
    if (data.isEmpty) return;
    _rustPlayer?.probeTail(tailBytes: data, tailOffset: tailOffset);
    final durMs = _rustPlayer?.getDurationMs().toInt() ?? 0;
    final bitrate = _rustPlayer?.getBitrate() ?? 0;
    if (durMs > 0) {
      _listener?.onDuration(Duration(milliseconds: durMs));
    }
    if (bitrate > 0) {
      _listener?.onBitrate(bitrate);
    }
  }

  @override
  Future<void> setDevice(String deviceId) async {
    final player = await _requireInitializedPlayer();
    await player.setDevice(deviceId: deviceId);
  }

  @override
  AudioDevice getCurrentDevice() {
    final player = _rustPlayer;
    if (player == null) return AudioDevice.auto;
    return _RustModelMapper.toAudioDevice(player.getCurrentDevice());
  }

  @override
  void setPauseOnDeviceChange(bool enabled) {
    _rustPlayer?.setPauseOnDeviceChange(enabled: enabled);
  }

  @override
  bool getPauseOnDeviceChange() {
    return _rustPlayer?.getPauseOnDeviceChange() ?? false;
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _dartReadRequestController.close();
    final sub = _eventSub;
    _eventSub = null;
    await sub?.cancel();
    final player = _rustPlayer;
    _rustPlayer = null;
    player?.dispose();
  }
}

/// Native FFI implementation of [PlatformService].
class NativePlatformService implements PlatformService {
  final StreamController<List<AudioDevice>> _deviceController =
      StreamController<List<AudioDevice>>.broadcast();

  static String _normalizeLocalPath(String filePath) {
    return filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
  }

  @override
  Future<List<AudioDevice>> getAudioDevices() async {
    await NativePlayerBackend.ensureRustInitialized();
    final list = await rust.getAudioDevices();
    return _RustModelMapper.toAudioDeviceList(list);
  }

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() => _deviceController.stream;

  @override
  List<AudioDevice> getAudioDevicesSync() {
    try {
      final list = rust.getAudioDevicesSync();
      return _RustModelMapper.toAudioDeviceList(list);
    } catch (_) {
      return const [AudioDevice.auto];
    }
  }

  @override
  Future<List<AudioDevice>> getCaptureDevices() async {
    await NativePlayerBackend.ensureRustInitialized();
    final list = await rust.getCaptureDevices();
    return _RustModelMapper.toAudioDeviceList(list);
  }

  @override
  List<AudioDevice> getCaptureDevicesSync() {
    try {
      final list = rust.getCaptureDevicesSync();
      return _RustModelMapper.toAudioDeviceList(list);
    } catch (_) {
      return const [AudioDevice.auto];
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
    await NativePlayerBackend.ensureRustInitialized();
    try {
      final res = await rust.analyzeAudioFile(
        path: _normalizeLocalPath(filePath),
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      return _RustModelMapper.toAnalysisResult(res);
    } catch (e) {
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
    try {
      final res = rust.analyzeAudioFileSync(
        path: _normalizeLocalPath(filePath),
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      return _RustModelMapper.toAnalysisResult(res);
    } catch (e) {
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
    await NativePlayerBackend.ensureRustInitialized();
    try {
      final res = await rust.analyzeAudioMemory(
        data: bytes,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      return _RustModelMapper.toAnalysisResult(res);
    } catch (e) {
      throw MiniaudioPlayerException.fromRustError(
        e,
        prefix: 'Analysis failed',
      );
    }
  }

  @override
  void setLogLevel(int level) {
    if (RustLib.instance.initialized) {
      try {
        rust.setLogLevel(level: level);
      } catch (_) {}
    } else {
      NativePlayerBackend.ensureRustInitialized().then((_) {
        try {
          rust.setLogLevel(level: level);
        } catch (_) {}
      });
    }
  }
}

PlayerBackend createPlayerBackend([dynamic player]) =>
    NativePlayerBackend(player);
PlatformService getPlatformService() => NativePlatformService();
