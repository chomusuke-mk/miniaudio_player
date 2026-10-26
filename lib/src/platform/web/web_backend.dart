import 'dart:async';
import 'dart:js_interop';
import 'dart:math';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../api/audio_analysis_result.dart';
import '../../api/audio_device.dart';
import '../../api/buffered_range.dart';
import '../../api/dsp_config.dart';
import '../../api/miniaudio_player.dart';
import '../../api/player_exception.dart';
import '../../api/player_state.dart';
import '../../api/silence_skip_config.dart';
import '../../api/visualizer_data.dart';
import '../../equalizer.dart';
import '../../reverb.dart';
import '../platform_backend.dart';
import 'wasm_loader.dart';
import 'web_interop.dart';
import 'web_worker_blob.dart';

class _SharedWebAudioContext {
  static web.AudioContext? _instance;
  static int _refCount = 0;
  static bool _workletModuleLoaded = false;
  static String? _workletBlobUrl;

  static Future<web.AudioContext> acquire(int sampleRate) async {
    _refCount++;
    if (_instance == null) {
      final options = web.AudioContextOptions(
        sampleRate: sampleRate > 0 ? sampleRate.toDouble() : 48000.0,
      );
      _instance = web.AudioContext(options);
    }
    if (!_workletModuleLoaded) {
      _workletBlobUrl ??= createWorkletBlobUrl();
      await _instance!.audioWorklet.addModule(_workletBlobUrl!).toDart;
      _workletModuleLoaded = true;
    }
    return _instance!;
  }

  static void release() {
    _refCount = (_refCount > 0) ? _refCount - 1 : 0;
    if (_refCount == 0 && _instance != null) {
      _instance!.close();
      _instance = null;
      _workletModuleLoaded = false;
    }
  }

  static void ensureResumed() {
    if (_instance != null && _instance!.state != 'running' && _instance!.state != 'closed') {
      try {
        _instance!.resume();
      } catch (_) {}
    }
  }
}

class _WebPlayerCleanupToken {
  final web.Worker worker;
  final web.AudioWorkletNode workletNode;
  bool disposed = false;

  _WebPlayerCleanupToken(this.worker, this.workletNode);

  void cleanup() {
    if (disposed) return;
    disposed = true;
    try {
      worker.postMessage(WebWorkerCommand(type: 'destroy'));
      worker.terminate();
      workletNode.disconnect();
      _SharedWebAudioContext.release();
    } catch (_) {}
  }
}

final Finalizer<_WebPlayerCleanupToken> _webFinalizer =
    Finalizer<_WebPlayerCleanupToken>((token) => token.cleanup());

class WebPlayerBackend implements PlayerBackend {
  static final Set<WebPlayerBackend> activeBackends = {};

  web.AudioContext? _audioContext;
  web.AudioWorkletNode? _workletNode;
  web.Worker? _worker;
  _WebPlayerCleanupToken? _cleanupToken;
  PlayerBackendListener? _listener;

  bool _isDisposed = false;
  AudioDevice _currentDevice = AudioDevice.auto;
  Completer<void>? _initCompleter;
  Completer<int>? _openCompleter;
  int _sampleRate = 48000;
  int _channels = 2;

  int _pinnedHeadSize = 0;
  int _audioDataOffset = 0;
  int _totalSize = 0;
  int _bufferCapacity = 2 * 1024 * 1024;
  int _rangeStart = 0;
  int _rangeEnd = 0;
  int _readCursorByte = 0;
  double _fillPercentage = 0.0;
  bool _isBuffering = false;
  bool _isEof = false;
  int _durationMs = 0;

  @override
  void setListener(PlayerBackendListener listener) {
    _listener = listener;
  }

  @override
  int get pinnedHeadSize => _pinnedHeadSize;

  @override
  Uint8List? getMetaBytes() => null;

  @override
  void init({
    required int sampleRate,
    required int channels,
    required int periodSize,
    String? playbackDeviceId,
  }) {
    _initCompleter = Completer<void>();
    _asyncInit(sampleRate, channels, periodSize, playbackDeviceId);
  }

  Future<void> _asyncInit(
    int sampleRate,
    int channels,
    int periodSize,
    String? playbackDeviceId,
  ) async {
    try {
      _sampleRate = sampleRate > 0 ? sampleRate : 48000;
      _channels = channels > 0 ? channels : 2;
      _audioContext = await _SharedWebAudioContext.acquire(sampleRate);

      final workletOptions = web.AudioWorkletNodeOptions(
        numberOfInputs: 0,
        numberOfOutputs: 1,
        outputChannelCount: [2.toJS].toJS,
      );
      _workletNode = web.AudioWorkletNode(
        _audioContext!,
        'miniaudio-worklet-processor',
        workletOptions,
      );
      _workletNode!.connect(_audioContext!.destination);

      final workerUrl = createEngineWorkerBlobUrl();
      _worker = web.Worker(workerUrl.toJS);
      activeBackends.add(this);

      _cleanupToken = _WebPlayerCleanupToken(_worker!, _workletNode!);
      _webFinalizer.attach(this, _cleanupToken!, detach: this);

      final channel = web.MessageChannel();
      _workletNode!.port.postMessage(
        'connect'.toJS,
        [channel.port2].toJS,
      );

      _worker!.onmessage = (web.MessageEvent e) {
        _handleWorkerMessage(e);
      }.toJS;

      final wasmUrl = await WasmLoader.resolveWasmUrl();
      _worker!.postMessage(
        WebWorkerCommand(
          type: 'init',
          wasmUrl: wasmUrl,
          sampleRate: sampleRate,
          channels: channels,
          periodSize: periodSize,
          logLevel: MiniaudioPlayer.globalConfig.logLevel.value,
        ),
      );

      _worker!.postMessage(
        WebWorkerCommand(type: 'connectWorklet'),
        [channel.port1].toJS,
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[miniaudio_player][ERROR][web] _asyncInit failed: $e\n$st');
      if (_initCompleter != null && !_initCompleter!.isCompleted) {
        _initCompleter!.completeError(e);
      }
    }
  }

  void _handleWorkerMessage(web.MessageEvent e) {
    final msg = e.data as WebWorkerMessage;
    final type = msg.type;

    switch (type) {
      case 'initialized':
        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.complete();
        }
        break;

      case 'opened':
        final res = msg.result ?? 0;
        _audioDataOffset = msg.audioDataOffset ?? 0;
        _pinnedHeadSize = msg.pinnedHeadSize ?? _audioDataOffset;
        if (_openCompleter != null && !_openCompleter!.isCompleted) {
          _openCompleter!.complete(res);
        }
        break;

      case 'telemetry':
        final dataArr = msg.data;
        if (dataArr != null) {
          _dispatchTelemetry(dataArr);
        }
        break;

      case 'error':
        final err = msg.error ?? 'Unknown worker error';
        // ignore: avoid_print
        print('[miniaudio_player][ERROR][web] Worker error: $err');
        if (_openCompleter != null && !_openCompleter!.isCompleted) {
          _openCompleter!.completeError(MiniaudioPlayerException(err));
        }
        break;
    }
  }

  void _dispatchTelemetry(JSArray<JSNumber> raw) {
    if (_isDisposed || _listener == null) return;

    final double posMs = raw[0].toDartDouble;
    final double durMs = raw[1].toDartDouble;
    final int stateInt = raw[2].toDartInt;
    final bool isPlaying = raw[3].toDartDouble != 0.0;
    final bool isBuffering = raw[4].toDartDouble != 0.0;
    final bool isCompleted = raw[5].toDartDouble != 0.0;
    final int bitrate = raw[6].toDartInt;
    final double silenceSavedMs = raw[9].toDartDouble;

    final double bufStartMs = raw[10].toDartDouble;
    final double bufEndMs = raw[11].toDartDouble;
    final double bufFillPct = raw[12].toDartDouble;
    final double streamPct = raw[13].toDartDouble;
    final bool isEof = raw[14].toDartDouble != 0.0;

    _durationMs = durMs.round();
    _fillPercentage = bufFillPct.clamp(0.0, 1.0);
    _isBuffering = isBuffering;
    _isEof = isEof;
    if (raw.length > 46 && raw[46].toDartDouble >= 0) {
      _readCursorByte = raw[46].toDartDouble.round();
    } else if (_durationMs > 0 && _totalSize > 0) {
      _readCursorByte = ((posMs / _durationMs) * _totalSize).round().clamp(0, _totalSize);
    }

    final bands = <double>[];
    for (int b = 0; b < 10; b++) {
      bands.add(raw[16 + b].toDartDouble);
    }
    final double rms = raw[26].toDartDouble;
    final double peak = raw[27].toDartDouble;
    final double left = raw[28].toDartDouble;
    final double right = raw[29].toDartDouble;
    final double volume = raw[30].toDartDouble;
    final double rate = raw[31].toDartDouble;
    final double pitch = raw.length > 32 ? raw[32].toDartDouble : 1.0;
    final double balance = raw.length > 33 ? raw[33].toDartDouble : 0.0;
    final bool mono = raw.length > 34 ? raw[34].toDartDouble != 0.0 : false;
    final int crossfeedIndex = raw.length > 35 ? raw[35].toDartInt : 0;
    final bool spatializer = raw.length > 36 ? raw[36].toDartDouble != 0.0 : false;
    final double spatializerWidth = raw.length > 37 ? raw[37].toDartDouble : 1.0;
    final bool reverbEnabled = raw.length > 38 ? raw[38].toDartDouble != 0.0 : false;
    final bool limiter = raw.length > 39 ? raw[39].toDartDouble != 0.0 : false;
    final double preampDb = raw.length > 40 ? raw[40].toDartDouble : 0.0;
    final bool rgEnabled = raw.length > 41 ? raw[41].toDartDouble != 0.0 : false;
    final double rgGainDb = raw.length > 42 ? raw[42].toDartDouble : 0.0;
    final double rgPeak = raw.length > 43 ? raw[43].toDartDouble : 0.0;
    final double rgPreampDb = raw.length > 44 ? raw[44].toDartDouble : 0.0;
    final bool rgPreventClipping = raw.length > 45 ? raw[45].toDartDouble != 0.0 : true;

    final bool visualizerEnabled = raw.length > 15 ? raw[15].toDartDouble != 0.0 : false;

    PlaybackState state;
    switch (stateInt) {
      case 1:
        state = PlaybackState.playing;
        break;
      case 2:
        state = PlaybackState.paused;
        break;
      case 3:
        state = PlaybackState.completed;
        break;
      case 4:
        state = PlaybackState.buffering;
        break;
      case 5:
        state = PlaybackState.error;
        break;
      case 6:
        state = PlaybackState.opening;
        break;
      default:
        state = PlaybackState.stopped;
        break;
    }

    _listener?.onPosition(Duration(milliseconds: posMs.round()));
    _listener?.onDuration(Duration(milliseconds: durMs.round()));
    _listener?.onState(state);
    _listener?.onPlaying(isPlaying);
    _listener?.onBuffering(isBuffering);
    _listener?.onCompleted(isCompleted);
    _listener?.onBitrate(bitrate);
    _listener?.onSilenceSaved(Duration(milliseconds: silenceSavedMs.round()));
    _listener?.onBufferedRange(
      BufferedRange(
        start: Duration(milliseconds: bufStartMs.round()),
        end: Duration(milliseconds: bufEndMs.round()),
        duration: Duration(milliseconds: durMs.round()),
        fillPercentage: bufFillPct.clamp(0.0, 1.0),
        streamPercentage: streamPct.clamp(0.0, 1.0),
        isBuffering: isBuffering,
        isEof: isEof,
      ),
    );
    _listener?.onVisualizer(
      VisualizerData(
        bands: bands,
        rms: rms,
        peak: peak,
        left: left,
        right: right,
      ),
    );
    _listener?.onVisualizerEnabled(visualizerEnabled);
    _listener?.onVolume(volume);
    _listener?.onRate(rate);
    _listener?.onPitch(pitch);
    _listener?.onBalance(balance);
    _listener?.onMono(mono);
    if (crossfeedIndex >= 0 && crossfeedIndex < CrossfeedMode.values.length) {
      _listener?.onCrossfeed(CrossfeedMode.values[crossfeedIndex]);
    }
    _listener?.onSpatializer(enabled: spatializer, width: spatializerWidth);
    _listener?.onReverb(Reverb(enabled: reverbEnabled));
    _listener?.onLimiter(limiter);
    _listener?.onPreamp(preampDb);
    _listener?.onReplayGain(
      ReplayGainConfig(
        enabled: rgEnabled,
        gainDb: rgGainDb,
        peak: rgPeak,
        preampDb: rgPreampDb,
        preventClipping: rgPreventClipping,
      ),
    );
  }

  Future<void> _ensureInitialized() async {
    if (_initCompleter != null) {
      await _initCompleter!.future;
    }
  }

  // --- Unified Stream Lifecycle ---

  @override
  Future<void> beginOpen() async {
    await _ensureInitialized();
    _pinnedHeadSize = 0;
    _audioDataOffset = 0;
    _rangeStart = 0;
    _rangeEnd = 0;
    _readCursorByte = 0;
    _isEof = false;
    _worker?.postMessage(WebWorkerCommand(type: 'stop'));
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
    await _ensureInitialized();
    _totalSize = totalSize;
    _bufferCapacity = bufferCapacityBytes > 0 ? bufferCapacityBytes : 2 * 1024 * 1024;
    _rangeStart = 0;
    _rangeEnd = initialBytes.length;
    _readCursorByte = 0;
    _isEof = !isLive && totalSize > 0 && initialBytes.length >= totalSize;

    _openCompleter = Completer<int>();
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'openStreamEx',
        bytes: initialBytes.toJS,
        tailBytes: tailBytes?.toJS,
        totalSize: totalSize,
        isLive: isLive,
        bufferCapacity: _bufferCapacity,
        encodingFormat: encodingFormat,
      ),
    );
    return await _openCompleter!.future;
  }

  @override
  int streamFeed(Uint8List chunk) {
    if (_isDisposed || chunk.isEmpty) return MapResult.errorInvalidState;
    if (_totalSize > 0 && (_rangeEnd - _readCursorByte) + chunk.length > _bufferCapacity) {
      return MapResult.errorBusy;
    }
    _rangeEnd += chunk.length;
    if (_rangeEnd - _rangeStart > _bufferCapacity) {
      _rangeStart = _rangeEnd - _bufferCapacity;
    }
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'streamFeed',
        bytes: chunk.toJS,
      ),
    );
    return MapResult.success;
  }

  @override
  int streamFlush(int newStreamOffset) {
    if (_isDisposed) return MapResult.errorInvalidState;
    _rangeStart = newStreamOffset;
    _rangeEnd = newStreamOffset;
    _readCursorByte = newStreamOffset;
    _isEof = false;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'streamFlush',
        newStreamOffset: newStreamOffset,
      ),
    );
    return MapResult.success;
  }

  @override
  int streamSeek(int positionMs, int newStreamOffset) {
    if (_isDisposed) return MapResult.errorInvalidState;
    final bool cacheHit =
        newStreamOffset >= _rangeStart && newStreamOffset < _rangeEnd;
    _readCursorByte = newStreamOffset;
    if (!cacheHit) {
      _rangeStart = newStreamOffset;
      _rangeEnd = newStreamOffset;
      _isEof = false;
      _isBuffering = true;
    }
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'streamSeek',
        positionMs: positionMs.toDouble(),
        newStreamOffset: newStreamOffset,
      ),
    );
    return cacheHit ? 1 : 0;
  }

  @override
  int streamGetSeekByte(int positionMs) {
    if (_durationMs <= 0 || _totalSize <= _audioDataOffset) {
      return _audioDataOffset;
    }
    final audioBytes = _totalSize - _audioDataOffset;
    final offset = _audioDataOffset + ((positionMs * audioBytes) ~/ _durationMs);
    return (offset ~/ 4) * 4;
  }

  @override
  int getAudioDataOffset() => _audioDataOffset;

  @override
  int streamEnd() {
    if (_isDisposed) return MapResult.errorInvalidState;
    _isEof = true;
    _worker?.postMessage(WebWorkerCommand(type: 'streamEnd'));
    return MapResult.success;
  }

  @override
  void notifyOpenError(int errorCode) {
    _listener?.onState(PlaybackState.error);
    _listener?.onError('Web error: $errorCode', errorCode);
  }

  @override
  BackendStreamStatus? getStreamStatus() {
    if (_isDisposed) return null;
    final fill = max(0, _rangeEnd - _rangeStart);
    return BackendStreamStatus(
      bufferCapacity: _bufferCapacity,
      bufferFill: fill,
      fillPercentage: _fillPercentage,
      isBuffering: _isBuffering,
      isEof: _isEof,
      readCursorByte: _readCursorByte,
      rangeStart: _rangeStart,
      rangeEnd: _rangeEnd,
    );
  }

  // --- Transport Controls ---

  @override
  Future<void> play() async {
    _SharedWebAudioContext.ensureResumed();
    await _ensureInitialized();
    _SharedWebAudioContext.ensureResumed();
    _worker?.postMessage(WebWorkerCommand(type: 'play'));
  }

  @override
  Future<void> pause() async {
    await _ensureInitialized();
    _worker?.postMessage(WebWorkerCommand(type: 'pause'));
  }

  @override
  Future<void> stop() async {
    await _ensureInitialized();
    _readCursorByte = _audioDataOffset;
    _worker?.postMessage(WebWorkerCommand(type: 'stop'));
  }

  @override
  Future<void> seek(Duration position) async {
    await _ensureInitialized();
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'seek',
        positionMs: position.inMilliseconds.toDouble(),
      ),
    );
  }

  // --- Audio & DSP Controls ---

  @override
  void setVolume(double volume) {
    _worker?.postMessage(WebWorkerCommand(type: 'setVolume', volume: volume));
  }

  @override
  void setRate(double rate) {
    _worker?.postMessage(WebWorkerCommand(type: 'setRate', rate: rate));
  }

  @override
  void setPitch(double pitch) {
    _worker?.postMessage(WebWorkerCommand(type: 'setPitch', pitch: pitch));
  }

  @override
  void setPan(double pan) {
    _worker?.postMessage(WebWorkerCommand(type: 'setPan', pan: pan));
  }

  @override
  void setBufferSize(int frames) {}

  @override
  void setEqualizerBand(int bandIndex, double gainDb) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setEqualizerBand',
        band: bandIndex,
        gainDb: gainDb,
      ),
    );
  }

  @override
  void setEqualizer(Equalizer params) {
    final gains = params.toList();
    final jsList = gains.map((g) => g.toJS).toList().toJS;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setEqualizerBands',
        gainsDb: jsList,
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
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setReverbConfig',
        enabled: enabled,
        roomSize: roomSize,
        damping: damping,
        width: width,
        wet: wet,
        dry: dry,
      ),
    );
    _listener?.onReverb(
      Reverb(
        enabled: enabled,
        roomSize: roomSize,
        damping: damping,
        width: width,
        wet: wet,
        dry: dry,
      ),
    );
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setCrossfeed',
        preset: mode.index,
      ),
    );
    _listener?.onCrossfeed(mode);
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setLimiterEnabled',
        enabled: enabled,
      ),
    );
    _listener?.onLimiter(enabled);
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setSilenceSkip',
        mode: config.mode.value,
        thresholdDb: config.thresholdDb,
        minDurationMs: config.minSilenceDuration.inMilliseconds,
      ),
    );
    _listener?.onSilenceConfig(config);
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setVisualizerEnabled',
        enabled: enabled,
      ),
    );
    _listener?.onVisualizerEnabled(enabled);
  }

  @override
  void setPreamp(double preampDb) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setPreamp',
        preampDb: preampDb,
      ),
    );
    _listener?.onPreamp(preampDb);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    if (config.enabled) {
      _worker?.postMessage(
        WebWorkerCommand(
          type: 'setReplayGain',
          enabled: true,
          gainDb: config.gainDb,
          peak: config.peak,
          preampDb: config.preampDb,
          preventClipping: config.preventClipping,
        ),
      );
    } else {
      _worker?.postMessage(
        WebWorkerCommand(
          type: 'clearReplayGain',
        ),
      );
    }
    _listener?.onReplayGain(config);
  }

  @override
  void setBalance(double balance) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setPan',
        pan: balance,
      ),
    );
    _listener?.onBalance(balance);
  }

  @override
  void setMono(bool enabled) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setMono',
        enabled: enabled,
      ),
    );
    _listener?.onMono(enabled);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setSpatializer',
        enabled: enabled,
        width: width,
      ),
    );
    _listener?.onSpatializer(enabled: enabled, width: width);
  }

  @override
  void setIcyMeta(Uint8List data) {}

  @override
  void probeTail(Uint8List data, int tailOffset) {
    if (_isDisposed || data.isEmpty) return;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'probeTail',
        bytes: data.toJS,
        tailOffset: tailOffset,
      ),
    );
  }

  @override
  dynamic get handle => null;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get channels => _channels;

  @override
  Future<void> setDevice(String deviceId) async {
    _currentDevice = AudioDevice(
      id: deviceId,
      name: deviceId.isEmpty ? 'System Default' : deviceId,
      isAuto: deviceId.isEmpty,
    );
  }

  @override
  AudioDevice getCurrentDevice() => _currentDevice;

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    activeBackends.remove(this);
    _webFinalizer.detach(this);
    _cleanupToken?.cleanup();
    _cleanupToken = null;
  }
}

class WebPlatformService implements PlatformService {
  @override
  Future<List<AudioDevice>> getAudioDevices() async {
    return [AudioDevice.auto];
  }

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() {
    return Stream.value([AudioDevice.auto]);
  }

  @override
  List<AudioDevice> getAudioDevicesSync() {
    return const [AudioDevice.auto];
  }

  @override
  AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    throw UnsupportedError(
      'analyzeAudioSync is not supported on web. Use analyzeAudio or analyzeAudioMemory.',
    );
  }

  @override
  Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    final resp = await web.window.fetch(filePath.toJS).toDart;
    final buf = await resp.arrayBuffer().toDart;
    final bytes = buf.toDart.asUint8List();
    return analyzeAudioMemory(
      bytes,
      replayGain: replayGain,
      waveform: waveform,
      waveformPoints: waveformPoints,
      targetLufs: targetLufs,
    );
  }

  @override
  Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    final workerUrl = createEngineWorkerBlobUrl();
    final worker = web.Worker(workerUrl.toJS);
    final completer = Completer<AudioAnalysisResult>();

    worker.onmessage = (web.MessageEvent e) {
      final msg = e.data as WebWorkerMessage;
      if (msg.type == 'initialized') {
        int flags = 0;
        if (replayGain) flags |= 0x01;
        if (waveform) flags |= 0x02;

        worker.postMessage(
          WebWorkerCommand(
            type: 'analyzeAudioMemory',
            id: 1,
            bytes: bytes.toJS,
            flags: flags,
            targetLufs: targetLufs,
            waveformPoints: waveformPoints,
          ),
        );
      } else if (msg.type == 'analysisResult') {
        try {
          if (msg.status == 0 && msg.analysisResult != null) {
            final res = msg.analysisResult!;
            final durMs = res.durationMs.round();
            final sr = res.sampleRate.round();
            final ch = res.channels.round();
            final br = res.bitrate.round();
            final pk = res.peak;

            ReplayGainResult? rg;
            if (replayGain && res.hasReplayGain) {
              rg = ReplayGainResult(
                gainDb: res.replayGainGainDb,
                peak: res.replayGainPeak,
                lufs: res.replayGainLufs,
              );
            }

            WaveformResult? wf;
            if (waveform && res.waveform != null) {
              final dartList = res.waveform!.toDart;
              wf = WaveformResult(points: dartList.map((e) => e.toDouble()).toList());
            }

            completer.complete(
              AudioAnalysisResult(
                duration: Duration(milliseconds: durMs),
                sampleRate: sr,
                channels: ch,
                bitrate: br,
                peak: pk,
                replayGain: rg,
                waveform: wf,
              ),
            );
          } else {
            completer.completeError(
              MiniaudioPlayerException(
                msg.error ?? 'Audio memory analysis failed with status ${msg.status}',
              ),
            );
          }
        } finally {
          worker.terminate();
        }
      } else if (msg.type == 'error') {
        completer.completeError(
          MiniaudioPlayerException(msg.error ?? 'Worker init error'),
        );
        worker.terminate();
      }
    }.toJS;

    final wasmUrl = await WasmLoader.resolveWasmUrl();
    worker.postMessage(
      WebWorkerCommand(
        type: 'init',
        wasmUrl: wasmUrl,
        sampleRate: 48000,
        channels: 2,
        periodSize: 2048,
      ),
    );

    return completer.future;
  }

  @override
  void setLogLevel(int level) {
    for (final b in WebPlayerBackend.activeBackends) {
      b._worker?.postMessage(WebWorkerCommand(type: 'setLogLevel', logLevel: level));
    }
  }
}

PlayerBackend createPlayerBackend([dynamic player]) => WebPlayerBackend();
PlatformService getPlatformService() => WebPlatformService();
