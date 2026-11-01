import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../../api/audio_analysis_result.dart';
import '../../api/audio_device.dart';
import '../../api/buffered_range.dart';
import '../../api/dsp_config.dart';
import '../../api/miniaudio_player.dart';
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

AudioDevice _toAudioDevice(rust_types.RustAudioDevice d) {
  if (d.isAuto) {
    return AudioDevice(
      id: 'auto',
      effectiveId: d.effectiveId,
      name: 'SYSTEM DEFAULT',
      resolvedName: d.name.isNotEmpty ? d.name : null,
      isAuto: true,
    );
  }
  return AudioDevice(
    id: d.id,
    effectiveId: d.effectiveId.isNotEmpty ? d.effectiveId : d.id,
    name: d.name.isEmpty ? 'Default' : d.name,
    isAuto: false,
  );
}

class NativePlayerBackend implements PlayerBackend, Finalizable {
  NativePlayerBackend([dynamic _]);

  rust.RustPlayer? _rustPlayer;
  StreamSubscription<rust_types.RustPlayerEvent>? _eventSub;
  PlayerBackendListener? _listener;
  bool _isDisposed = false;
  final _dartReadRequestController =
      StreamController<rust_types.RustDartReadRequest>.broadcast();

  Stream<rust_types.RustDartReadRequest> get onDartReadRequest =>
      _dartReadRequestController.stream;

  int _initSampleRate = 0;
  int _initChannels = 0;
  int _initPeriodSize = 0;
  String? _initPlaybackDeviceId;

  static Future<void>? _initFuture;

  static ExternalLibrary _findRustLibrary() {
    final candidatePaths = [
      'rust/target/debug/libminiaudio_player.so',
      'rust/target/release/libminiaudio_player.so',
      '.dart_tool/hooks_runner/shared/miniaudio_player/build/6b4ebf10e7/libminiaudio_player.so',
      'libminiaudio_player.so',
    ];
    for (final p in candidatePaths) {
      if (File(p).existsSync()) {
        return ExternalLibrary.open(p);
      }
    }
    return ExternalLibrary.open('libminiaudio_player.so');
  }

  static Future<void> ensureRustInitialized() {
    if (RustLib.instance.initialized) return Future.value();
    return _initFuture ??= () async {
      try {
        await RustLib.init();
      } catch (_) {
        try {
          await RustLib.init(externalLibrary: _findRustLibrary());
        } catch (_) {}
      }
      try {
        rust.setLogLevel(level: MiniaudioPlayer.globalConfig.logLevel.value);
      } catch (_) {}
    }();
  }

  void _ensureNotDisposed() {
    if (_isDisposed) {
      throw const MiniaudioPlayerException('Player is disposed');
    }
  }

  void _createPlayer() {
    if (_rustPlayer != null || _isDisposed) return;
    _rustPlayer = rust.RustPlayer(
      sampleRate: _initSampleRate,
      channels: _initChannels,
      periodSize: _initPeriodSize,
      playbackDeviceId: _initPlaybackDeviceId,
    );
    _setupEventSubscription();
  }

  void _setupEventSubscription() {
    if (_rustPlayer == null) return;
    _eventSub?.cancel();
    _eventSub = _rustPlayer!.subscribeEvents().listen(_onRustEvent);
  }

  PlaybackState _mapState(int stateInt) {
    switch (stateInt) {
      case 0:
        return PlaybackState.stopped;
      case 1:
        return PlaybackState.playing;
      case 2:
        return PlaybackState.paused;
      case 3:
        return PlaybackState.completed;
      case 4:
        return PlaybackState.buffering;
      case 5:
        return PlaybackState.error;
      case 6:
        return PlaybackState.opening;
      default:
        return PlaybackState.stopped;
    }
  }

  static double _f32(double v) => (v * 1e6).roundToDouble() / 1e6;

  void _onRustEvent(rust_types.RustPlayerEvent event) {
    if (_isDisposed) return;
    event.when(
      state: (s) => _listener?.onState(_mapState(s)),
      position: (ms) => _listener?.onPosition(Duration(milliseconds: ms.toInt())),
      duration: (ms) => _listener?.onDuration(Duration(milliseconds: ms.toInt())),
      isPlaying: (v) => _listener?.onPlaying(v),
      isBuffering: (v) => _listener?.onBuffering(v),
      isCompleted: (v) => _listener?.onCompleted(v),
      volume: (v) => _listener?.onVolume(_f32(v)),
      rate: (v) => _listener?.onRate(_f32(v)),
      pitch: (v) => _listener?.onPitch(_f32(v)),
      bitrate: (v) => _listener?.onBitrate(v),
      bufferSize: (v) => _listener?.onBufferSize(v),
      device: (d) => _listener?.onDevice(_toAudioDevice(d)),
      visualizer: (vz) => _listener?.onVisualizer(VisualizerData(
        bands: vz.bands.map(_f32).toList(),
        rms: _f32(vz.rms),
        peak: _f32(vz.peak),
        left: _f32(vz.left),
        right: _f32(vz.right),
      )),
      visualizerEnabled: (v) => _listener?.onVisualizerEnabled(v),
      bufferedRange: (br) => _listener?.onBufferedRange(BufferedRange(
        start: Duration(milliseconds: br.startMs.toInt()),
        end: Duration(milliseconds: br.endMs.toInt()),
        duration: Duration(milliseconds: br.durationMs.toInt()),
        fillPercentage: br.fillPercentage.clamp(0.0, 1.0),
        percentage: br.streamPercentage.clamp(0.0, 1.0),
        isBuffering: br.isBuffering,
        isEof: br.isEof,
      )),
      silenceConfig: (sc) => _listener?.onSilenceConfig(SilenceSkipConfig.fromRaw(
        mode: sc.mode,
        thresholdDb: _f32(sc.thresholdDb),
        minSilenceDurationMs: sc.minSilenceDurationMs,
        paddingMs: sc.paddingMs,
      )),
      silenceSaved: (ms) => _listener?.onSilenceSaved(Duration(milliseconds: ms.toInt())),
      equalizer: (eq) => _listener?.onEqualizer(Equalizer.fromList(eq.gains.map(_f32).toList())),
      preamp: (db) => _listener?.onPreamp(_f32(db)),
      replayGain: (rg) => _listener?.onReplayGain(ReplayGainConfig(
        gainDb: _f32(rg.gainDb),
        peak: _f32(rg.peak),
        preventClipping: rg.preventClipping,
        enabled: rg.enabled,
      )),
      balance: (b) => _listener?.onBalance(_f32(b)),
      mono: (m) => _listener?.onMono(m),
      crossfeed: (cf) => _listener?.onCrossfeed(switch (cf) {
        1 => CrossfeedMode.moffatBauer,
        2 => CrossfeedMode.chuMoy,
        _ => CrossfeedMode.off,
      }),
      spatializer: (en, w) => _listener?.onSpatializer(enabled: en, width: _f32(w)),
      reverb: (rv) => _listener?.onReverb(Reverb(
        enabled: rv.enabled,
        roomSize: _f32(rv.roomSize),
        damping: _f32(rv.damping),
        width: _f32(rv.width),
        wet: _f32(rv.wet),
        dry: _f32(rv.dry),
      )),
      limiter: (l) => _listener?.onLimiter(l),
      dartReadRequest: (req) => _dartReadRequestController.add(req),
      error: (msg, code) => _listener?.onError(msg, code),
    );
  }

  @override
  dynamic get handle {
    final raw = _rustPlayer?.getRawHandle().toInt() ?? 0;
    return raw == 0 ? nullptr : Pointer<Void>.fromAddress(raw);
  }

  @override
  int get sampleRate => _rustPlayer?.getSampleRate() ?? 0;

  @override
  int get channels => _rustPlayer?.getChannels() ?? 0;

  @override
  int get pinnedHeadSize => _rustPlayer?.getPinnedHeadSize().toInt() ?? 0;

  @override
  Uint8List? getMetaBytes() {
    final bytes = _rustPlayer?.getMetaBytes();
    return bytes == null ? null : Uint8List.fromList(bytes);
  }

  @override
  void setListener(PlayerBackendListener listener) {
    _listener = listener;
  }

  @override
  void init({
    required int sampleRate,
    required int channels,
    required int periodSize,
    String? playbackDeviceId,
  }) {
    _initSampleRate = sampleRate;
    _initChannels = channels;
    _initPeriodSize = periodSize;
    _initPlaybackDeviceId = playbackDeviceId;

    if (RustLib.instance.initialized) {
      _createPlayer();
    } else {
      ensureRustInitialized().then((_) {
        if (_rustPlayer == null && !_isDisposed) {
          _createPlayer();
        }
      });
    }
  }

  MiniaudioPlayerException _toPlayerException(Object error) {
    if (error is MiniaudioPlayerException) return error;
    final str = error.toString();
    final match = RegExp(r'error (-?\d+)').firstMatch(str);
    final code = match != null ? int.parse(match.group(1)!) : MapResult.errorGeneric;
    return MiniaudioPlayerException(str, errorCode: code);
  }

  AudioTrackMetadata _buildMetadata({
    required String? sourcePath,
    required Uint8List? bytes,
    required bool isNetwork,
  }) {
    final metaBytes = bytes ?? _rustPlayer?.getMetaBytes();
    final codec = (metaBytes != null && metaBytes.isNotEmpty)
        ? AudioCodec.detect(metaBytes)
        : AudioCodec.unknown;
    final durMs = _rustPlayer?.getDurationMs().toInt() ?? 0;
    final bitrate = _rustPlayer?.getBitrate() ?? 0;
    final sampleRate = _rustPlayer?.getSampleRate() ?? 0;
    final channels = _rustPlayer?.getChannels() ?? 0;
    final isLive = _rustPlayer?.isLiveStream() ?? false;
    final offset = _rustPlayer?.getAudioDataOffset().toInt() ?? 0;
    final format = AudioFormat.fromCodec(codec);

    return AudioTrackMetadata(
      codec: codec,
      format: format,
      formatName: format.extension,
      duration: Duration(milliseconds: durMs > 0 ? durMs : 0),
      totalBytes: isLive ? -1 : 0,
      bitrate: bitrate,
      sampleRate: sampleRate,
      channels: channels,
      isNetwork: isNetwork,
      isLiveStream: isLive,
      audioDataOffset: offset,
      uri: sourcePath != null ? Uri.tryParse(sourcePath) : null,
    );
  }

  // --- Unified Stream Lifecycle ---

  @override
  Future<void> openSource(String source, {Map<String, String>? headers}) async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();

    List<rust_types.RustHttpHeader>? rustHeaders;
    if (headers != null && headers.isNotEmpty) {
      rustHeaders = headers.entries
          .map((e) => rust_types.RustHttpHeader(key: e.key, value: e.value))
          .toList();
    }

    try {
      await _rustPlayer!.openSource(source: source, headers: rustHeaders);
    } catch (e) {
      throw _toPlayerException(e);
    }
    final durMs = _rustPlayer!.getDurationMs().toInt();
    final bitrate = _rustPlayer!.getBitrate();
    final isNet = source.startsWith('http://') ||
        source.startsWith('https://') ||
        source.startsWith('icy://');
    final meta = _buildMetadata(
      sourcePath: source,
      bytes: null,
      isNetwork: isNet,
    );
    _listener?.onDuration(Duration(milliseconds: durMs > 0 ? durMs : 0));
    _listener?.onBitrate(bitrate > 0 ? bitrate : 0);
    _listener?.onPosition(Duration.zero);
    _listener?.onCompleted(false);
    _listener?.onTrackMetadata(meta);
  }

  @override
  Future<void> openMemory(Uint8List bytes) async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();

    try {
      await _rustPlayer!.openMemory(data: bytes);
    } catch (e) {
      throw _toPlayerException(e);
    }
    final durMs = _rustPlayer!.getDurationMs().toInt();
    final bitrate = _rustPlayer!.getBitrate();
    final meta = _buildMetadata(
      sourcePath: null,
      bytes: bytes,
      isNetwork: false,
    );
    _listener?.onDuration(Duration(milliseconds: durMs > 0 ? durMs : 0));
    _listener?.onBitrate(bitrate > 0 ? bitrate : 0);
    _listener?.onPosition(Duration.zero);
    _listener?.onCompleted(false);
    _listener?.onTrackMetadata(meta);
  }

  @override
  Future<void> beginOpen() async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();
    await _rustPlayer!.beginOpen();
  }

  @override
  Future<int> openStreamEx({
    required Uint8List initialBytes,
    Uint8List? tailBytes,
    required int totalSize,
    required bool isLive,
    required int bufferCapacityBytes,
    int encodingFormat = 0,
  }) async {
    _ensureNotDisposed();
    if (initialBytes.isEmpty) {
      return MapResult.errorInvalidArgs;
    }
    await ensureRustInitialized();
    _createPlayer();

    final res = await _rustPlayer!.openStreamEx(
      initialBytes: initialBytes,
      tailBytes: tailBytes,
      totalBytes: totalSize,
      isLive: isLive,
      bufferCapacityBytes: BigInt.from(bufferCapacityBytes),
      encodingFormat: encodingFormat,
    );

    if (res == MapResult.success) {
      final durMs = _rustPlayer!.getDurationMs().toInt();
      final bitrate = _rustPlayer!.getBitrate();
      _listener?.onDuration(Duration(milliseconds: durMs > 0 ? durMs : 0));
      _listener?.onBitrate(bitrate > 0 ? bitrate : 0);
      _listener?.onPosition(Duration.zero);
      _listener?.onCompleted(false);
    }
    return res;
  }

  @override
  Future<void> openCustomStream({
    required int streamId,
    int? totalSize,
    required bool isSeekable,
    required Uint8List initialBytes,
  }) async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();

    try {
      await _rustPlayer!.openCustomStream(
        streamId: streamId,
        totalSize: totalSize != null ? BigInt.from(totalSize) : null,
        isSeekable: isSeekable,
        initialBytes: initialBytes,
      );
    } catch (e) {
      throw _toPlayerException(e);
    }

    final durMs = _rustPlayer!.getDurationMs().toInt();
    final bitrate = _rustPlayer!.getBitrate();
    final meta = _buildMetadata(
      sourcePath: null,
      bytes: initialBytes,
      isNetwork: false,
    );
    _listener?.onDuration(Duration(milliseconds: durMs > 0 ? durMs : 0));
    _listener?.onBitrate(bitrate > 0 ? bitrate : 0);
    _listener?.onTrackMetadata(meta);
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
  int streamFeed(Uint8List chunk) {
    if (_isDisposed || _rustPlayer == null || chunk.isEmpty) {
      return MapResult.errorInvalidState;
    }
    try {
      return _rustPlayer!.streamFeed(data: chunk);
    } catch (_) {
      return MapResult.errorInvalidState;
    }
  }

  @override
  int streamFlush(int newStreamOffset) {
    if (_isDisposed || _rustPlayer == null) {
      return MapResult.errorInvalidState;
    }
    try {
      return _rustPlayer!.streamFlush(newStreamOffset: newStreamOffset);
    } catch (_) {
      return MapResult.errorInvalidState;
    }
  }

  @override
  int streamSeek(int positionMs, int newStreamOffset) {
    if (_isDisposed || _rustPlayer == null) {
      return MapResult.errorInvalidState;
    }
    final durMs = _rustPlayer!.getDurationMs().toInt();
    var clampedMs = positionMs < 0 ? 0 : positionMs;
    if (durMs > 0 && clampedMs > durMs) {
      clampedMs = durMs;
    }
    try {
      final res = _rustPlayer!.streamSeek(
        positionMs: clampedMs,
        newStreamOffset: newStreamOffset,
      );
      if (res >= 0) {
        final isComp = _rustPlayer!.isCompleted();
        _listener?.onCompleted(isComp);
        if (!isComp) {
          _listener?.onPosition(Duration(milliseconds: clampedMs));
        }
      }
      return res;
    } catch (_) {
      return MapResult.errorInvalidState;
    }
  }

  @override
  int streamGetSeekByte(int positionMs) {
    if (_isDisposed || _rustPlayer == null) return -1;
    try {
      return _rustPlayer!.streamGetSeekByte(positionMs: positionMs).toInt();
    } catch (_) {
      return -1;
    }
  }

  @override
  int getAudioDataOffset() {
    if (_isDisposed || _rustPlayer == null) return 0;
    try {
      return _rustPlayer!.getAudioDataOffset().toInt();
    } catch (_) {
      return 0;
    }
  }

  @override
  int streamEnd() {
    if (_isDisposed || _rustPlayer == null) {
      return MapResult.errorInvalidState;
    }
    try {
      return _rustPlayer!.streamEnd();
    } catch (_) {
      return MapResult.errorInvalidState;
    }
  }

  @override
  void notifyOpenError(int errorCode) {
    if (_isDisposed || _rustPlayer == null) return;
    final int code = errorCode < 0 ? errorCode : MapResult.errorDecodeFailed;
    try {
      _rustPlayer!.notifyOpenError(errorCode: code);
    } catch (_) {}
  }

  @override
  BackendStreamStatus? getStreamStatus() {
    if (_isDisposed || _rustPlayer == null) return null;
    try {
      final s = _rustPlayer!.getStreamStatus();
      return BackendStreamStatus(
        bufferCapacity: s.bufferCapacity.toInt(),
        bufferFill: s.bufferFill.toInt(),
        fillPercentage: s.fillPercentage,
        isBuffering: s.isBuffering,
        isEof: s.isEof,
        readCursorByte: s.readCursorByte.toInt(),
        rangeStart: s.rangeStart.toInt(),
        rangeEnd: s.rangeEnd.toInt(),
      );
    } catch (_) {
      return null;
    }
  }

  // --- Transport Controls ---

  @override
  Future<void> play() async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();
    try {
      await _rustPlayer!.play();
    } catch (_) {}
    _listener?.onState(PlaybackState.playing);
    _listener?.onCompleted(false);
    _listener?.onPlaying(true);
  }

  @override
  Future<void> pause() async {
    _ensureNotDisposed();
    if (_rustPlayer == null) return;
    try {
      await _rustPlayer!.pause();
    } catch (_) {}
    _listener?.onPlaying(false);
    _listener?.onState(PlaybackState.paused);
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    if (_rustPlayer == null) return;
    try {
      await _rustPlayer!.stop();
    } catch (_) {}
    _listener?.onPlaying(false);
    _listener?.onCompleted(false);
    _listener?.onPosition(Duration.zero);
    _listener?.onState(PlaybackState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureNotDisposed();
    await ensureRustInitialized();
    _createPlayer();
    final durMs = _rustPlayer!.getDurationMs().toInt();
    var targetMs = position.inMilliseconds;
    if (targetMs < 0) targetMs = 0;
    if (durMs > 0 && targetMs > durMs) {
      targetMs = durMs;
    }
    try {
      await _rustPlayer!.seek(positionMs: targetMs);
    } catch (_) {}
    final isComp = _rustPlayer!.isCompleted();
    _listener?.onCompleted(isComp);
    if (!isComp) {
      _listener?.onPosition(Duration(milliseconds: targetMs));
    }
  }

  // --- Audio & DSP Controls ---

  @override
  void setVolume(double volume) {
    _rustPlayer?.setVolume(volume: volume);
  }

  @override
  void setRate(double rate) {
    _rustPlayer?.setRate(rate: rate);
  }

  @override
  void setPitch(double pitch) {
    _rustPlayer?.setPitch(pitch: pitch);
  }

  @override
  void setPan(double pan) {
    _rustPlayer?.setBalance(pan: pan);
  }

  @override
  void setBufferSize(int frames) {
    _rustPlayer?.setBufferSize(frames: frames);
  }

  @override
  void setEqualizerBand(int bandIndex, double gainDb) {
    _rustPlayer?.setEqualizerBand(band: bandIndex, gainDb: gainDb);
  }

  @override
  void setEqualizer(Equalizer params) {
    _ensureNotDisposed();
    _rustPlayer?.setEqualizer(
      params: rust_types.RustEqualizerParams(
        gains: Float32List.fromList(params.toList()),
        enabled: true,
      ),
    );
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
    _rustPlayer?.setReverb(
      params: rust_types.RustReverbParams(
        roomSize: roomSize,
        damping: damping,
        wet: wet,
        dry: dry,
        width: width,
        mode: 0.0,
        enabled: enabled,
      ),
    );
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _ensureNotDisposed();
    _rustPlayer?.setCrossfeed(mode: mode.index);
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setLimiter(enabled: enabled);
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _ensureNotDisposed();
    final threshold = config.thresholdDb.clamp(-90.0, -10.0);
    final minMs = config.minSilenceDuration.inMilliseconds.clamp(50, 5000);
    final maxPad = minMs ~/ 2;
    final padMs = config.padding.inMilliseconds.clamp(0, maxPad);

    _rustPlayer?.setSilenceConfig(
      config: rust_types.RustSilenceConfig(
        mode: config.mode.value,
        thresholdDb: threshold,
        minSilenceDurationMs: minMs,
        paddingMs: padMs,
        enabled: config.mode != SilenceSkipMode.disabled,
      ),
    );
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    _rustPlayer?.setVisualizerEnabled(enabled: enabled);
  }

  @override
  bool get isVisualizerEnabled => _rustPlayer?.isVisualizerEnabled() ?? false;

  @override
  void setPreamp(double preampDb) {
    _ensureNotDisposed();
    _rustPlayer?.setPreamp(preampDb: preampDb);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    _ensureNotDisposed();
    if (!config.enabled) {
      _rustPlayer?.clearReplayGain();
    } else {
      _rustPlayer?.setReplayGain(
        gainDb: config.gainDb,
        peak: config.peak > 0 ? config.peak : 0.0,
        preventClipping: config.preventClipping,
      );
    }
  }

  @override
  void setBalance(double balance) {
    _ensureNotDisposed();
    _rustPlayer?.setBalance(pan: balance.clamp(-1.0, 1.0));
  }

  @override
  void setMono(bool enabled) {
    _ensureNotDisposed();
    _rustPlayer?.setMono(enabled: enabled);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _ensureNotDisposed();
    _rustPlayer?.setSpatializer(enabled: enabled, width: width);
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
    await ensureRustInitialized();
    _createPlayer();
    await _rustPlayer?.setDevice(deviceId: deviceId);
  }

  @override
  AudioDevice getCurrentDevice() {
    if (_rustPlayer == null) return AudioDevice.auto;
    final d = _rustPlayer!.getCurrentDevice();
    return _toAudioDevice(d);
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
    _dartReadRequestController.close();
    final sub = _eventSub;
    _eventSub = null;
    unawaited(sub?.cancel());
    final player = _rustPlayer;
    _rustPlayer = null;
    player?.dispose();
  }
}

class NativePlatformService implements PlatformService {
  final StreamController<List<AudioDevice>> _deviceController =
      StreamController<List<AudioDevice>>.broadcast();

  AudioAnalysisResult _mapAnalysisResult(rust_types.RustAudioAnalysisResult res) {
    ReplayGainResult? rg;
    if (res.integratedLufs != 0.0) {
      rg = ReplayGainResult(
        gainDb: res.replayGainDb,
        peak: res.peakAmplitude,
        lufs: res.integratedLufs,
      );
    }
    WaveformResult? wf;
    if (res.waveformPeaks.isNotEmpty) {
      wf = WaveformResult(points: res.waveformPeaks.toList());
    }
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

  @override
  Future<List<AudioDevice>> getAudioDevices() async {
    await NativePlayerBackend.ensureRustInitialized();
    final list = await rust.getAudioDevices();
    final result = <AudioDevice>[AudioDevice.auto];
    for (final d in list) {
      result.add(_toAudioDevice(d));
    }
    return result;
  }

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() => _deviceController.stream;

  @override
  List<AudioDevice> getAudioDevicesSync() {
    try {
      final list = rust.getAudioDevicesSync();
      final result = <AudioDevice>[AudioDevice.auto];
      for (final d in list) {
        result.add(_toAudioDevice(d));
      }
      return result;
    } catch (_) {
      return [AudioDevice.auto];
    }
  }

  @override
  Future<List<AudioDevice>> getCaptureDevices() async {
    await NativePlayerBackend.ensureRustInitialized();
    final list = await rust.getCaptureDevices();
    final result = <AudioDevice>[AudioDevice.auto];
    for (final d in list) {
      result.add(_toAudioDevice(d));
    }
    return result;
  }

  @override
  List<AudioDevice> getCaptureDevicesSync() {
    try {
      final list = rust.getCaptureDevicesSync();
      final result = <AudioDevice>[AudioDevice.auto];
      for (final d in list) {
        result.add(_toAudioDevice(d));
      }
      return result;
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
    await NativePlayerBackend.ensureRustInitialized();
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    try {
      final res = await rust.analyzeAudioFile(
        path: path,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      return _mapAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      final str = e.toString();
      final match = RegExp(r'error (-?\d+)').firstMatch(str);
      final code = match != null ? int.parse(match.group(1)!) : MapResult.errorGeneric;
      throw MiniaudioPlayerException('Analysis failed with error $code', errorCode: code);
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
    final path = filePath.startsWith('file://')
        ? Uri.parse(filePath).toFilePath()
        : filePath;
    try {
      final res = rust.analyzeAudioFileSync(
        path: path,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: waveformPoints,
        targetLufs: targetLufs,
      );
      return _mapAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      final str = e.toString();
      final match = RegExp(r'error (-?\d+)').firstMatch(str);
      final code = match != null ? int.parse(match.group(1)!) : MapResult.errorGeneric;
      throw MiniaudioPlayerException('Analysis failed with error $code', errorCode: code);
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
      return _mapAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      final str = e.toString();
      final match = RegExp(r'error (-?\d+)').firstMatch(str);
      final code = match != null ? int.parse(match.group(1)!) : MapResult.errorGeneric;
      throw MiniaudioPlayerException('Analysis failed with error $code', errorCode: code);
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
