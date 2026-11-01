import 'dart:async';
import 'dart:js_interop';
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
import '../../api/spatial.dart';
import '../../api/visualizer_data.dart';
import '../../equalizer.dart';
import '../../reverb.dart';
import '../../rust/api/types.dart' show RustDartReadRequest;
import '../platform_backend.dart';
import 'wasm_loader.dart';
import 'web_interop.dart';
import 'web_worker_blob.dart';

class _WebCleanupToken {
  web.Worker? worker;
  web.AudioContext? audioCtx;
  web.AudioWorkletNode? workletNode;
  bool cleaned = false;

  void cleanup() {
    if (cleaned) return;
    cleaned = true;
    try {
      worker?.postMessage(WebWorkerCommand(type: 'dispose'));
      worker?.terminate();
      workletNode?.disconnect();
      audioCtx?.close();
    } catch (_) {}
    worker = null;
    workletNode = null;
    audioCtx = null;
  }
}

final Finalizer<_WebCleanupToken> _webFinalizer = Finalizer(
  (token) => token.cleanup(),
);

/// WebAssembly + AudioWorklet + Web Worker implementation of [PlayerBackend].
class WebPlayerBackend implements PlayerBackend {
  static final Set<WebPlayerBackend> activeBackends = <WebPlayerBackend>{};

  PlayerBackendListener? _listener;
  web.Worker? _worker;
  web.AudioContext? _audioCtx;
  _WebCleanupToken? _cleanupToken;

  Completer<void>? _initCompleter;
  Completer<int>? _openCompleter;

  int _sampleRate = 48000;
  int _channels = 2;
  int _periodSize = 2048;

  bool _isDisposed = false;
  int _pinnedHeadSize = 0;

  double _volume = 1.0;
  double _rate = 1.0;
  double _pitch = 1.0;
  int _durationMs = 0;
  int _positionMs = 0;
  int _bitrate = 0;
  int _silenceSavedMs = 0;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  PlaybackState _playbackState = PlaybackState.stopped;

  Equalizer _equalizer = Equalizer.flat;
  AudioDevice _currentDevice = AudioDevice.auto;
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();
  bool _visualizerEnabled = false;
  double _preamp = 0.0;
  ReplayGainConfig _replayGain = const ReplayGainConfig();
  double _balance = 0.0;
  bool _mono = false;
  CrossfeedMode _crossfeed = CrossfeedMode.off;
  bool _spatializerEnabled = false;
  double _spatializerWidth = 1.0;
  Reverb _reverb = Reverb.off;
  bool _limiterEnabled = true;
  bool _pauseOnDeviceChange = false;

  WebPlayerBackend() {
    activeBackends.add(this);
  }

  @override
  Stream<RustDartReadRequest> get onDartReadRequest => const Stream.empty();

  @override
  dynamic get handle => null;

  @override
  int get sampleRate => _sampleRate;

  @override
  int get channels => _channels;

  @override
  int get pinnedHeadSize => _pinnedHeadSize;

  @override
  Uint8List? getMetaBytes() => null;

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
    _sampleRate = sampleRate > 0 ? sampleRate : 48000;
    _channels = channels > 0 ? channels : 2;
    _periodSize = periodSize > 0 ? periodSize : 2048;
    _ensureWorkerInitialized();
  }

  Future<void> _ensureWorkerInitialized() async {
    if (_initCompleter != null) return _initCompleter!.future;
    final completer = Completer<void>();
    _initCompleter = completer;

    try {
      final wasmUrl = await WasmLoader.resolveWasmUrl();
      if (_isDisposed) {
        completer.complete();
        return;
      }

      final workerUrl = createEngineWorkerBlobUrl();
      final worker = web.Worker(workerUrl.toJS);
      _worker = worker;

      final token = _WebCleanupToken()..worker = worker;
      _cleanupToken = token;
      _webFinalizer.attach(this, token, detach: this);

      worker.onmessage = ((web.MessageEvent e) {
        _handleWorkerMessage(e.data as WebWorkerMessage);
      }).toJS;

      worker.onerror = ((web.Event e) {
        if (!completer.isCompleted) {
          completer.completeError(
            const MiniaudioPlayerException('Web Worker initialization failed'),
          );
        }
      }).toJS;

      worker.postMessage(
        WebWorkerCommand(
          type: 'init',
          wasmUrl: wasmUrl,
          sampleRate: _sampleRate,
          channels: _channels,
          periodSize: _periodSize,
          logLevel: MiniaudioPlayer.globalConfig.logLevel.value,
        ),
      );
    } catch (e) {
      if (!completer.isCompleted) {
        completer.completeError(e);
      }
    }

    return completer.future;
  }

  Future<void> _ensureAudioContextInitialized() async {
    if (_audioCtx != null) {
      if (_audioCtx!.state == 'suspended') {
        try {
          await _audioCtx!.resume().toDart;
        } catch (_) {}
      }
      return;
    }

    try {
      final ctx = web.AudioContext(
        web.AudioContextOptions(sampleRate: _sampleRate.toDouble()),
      );
      _audioCtx = ctx;
      _cleanupToken?.audioCtx = ctx;

      final workletUrl = createWorkletBlobUrl();
      await ctx.audioWorklet.addModule(workletUrl).toDart;

      final node = web.AudioWorkletNode(
        ctx,
        'miniaudio-processor',
        web.AudioWorkletNodeOptions(
          numberOfInputs: 0,
          numberOfOutputs: 1,
          outputChannelCount: [_channels.toJS].toJS,
        ),
      );
      node.connect(ctx.destination);
      _cleanupToken?.workletNode = node;

      final channel = web.MessageChannel();
      node.port.postMessage(
        {'type': 'port', 'port': channel.port1}.jsify(),
        [channel.port1].toJS,
      );
      _worker?.postMessage(
        {'type': 'workletPort', 'port': channel.port2}.jsify(),
        [channel.port2].toJS,
      );

      if (ctx.state == 'suspended') {
        try {
          await ctx.resume().toDart;
        } catch (_) {}
      }
    } catch (_) {}
  }

  void _handleWorkerMessage(WebWorkerMessage msg) {
    if (_isDisposed) return;

    switch (msg.type) {
      case 'initialized':
        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.complete();
        }
        _syncInitialDspStateToWorker();

      case 'opened':
        final res = msg.result ?? 0;
        _pinnedHeadSize = msg.pinnedHeadSize ?? (msg.audioDataOffset ?? 0);
        if (_openCompleter != null && !_openCompleter!.isCompleted) {
          if (res == 0) {
            _openCompleter!.complete(0);
          } else {
            _openCompleter!.completeError(
              MiniaudioPlayerException(
                msg.error ?? 'Failed to open audio source in Web Worker',
                errorCode: res,
              ),
            );
          }
          _openCompleter = null;
        }

      case 'telemetry':
        final arr = msg.data;
        if (arr != null) {
          _processTelemetryPacket(
            arr.toDart.map((e) => e.toDartDouble).toList(),
          );
        }

      case 'streamError':
        _playbackState = PlaybackState.error;
        _listener?.onState(PlaybackState.error);
        _listener?.onError(
          msg.error ?? 'Web stream error',
          MapResult.errorDecodeFailed,
        );

      case 'error':
        final err = msg.error ?? 'Web Worker error';
        if (_initCompleter != null && !_initCompleter!.isCompleted) {
          _initCompleter!.completeError(MiniaudioPlayerException(err));
        }
        if (_openCompleter != null && !_openCompleter!.isCompleted) {
          _openCompleter!.completeError(MiniaudioPlayerException(err));
          _openCompleter = null;
        }
        _playbackState = PlaybackState.error;
        _listener?.onState(PlaybackState.error);
        _listener?.onError(err, MapResult.errorGeneric);
    }
  }

  void _syncInitialDspStateToWorker() {
    final w = _worker;
    if (w == null) return;
    if (_volume != 1.0) setVolume(_volume);
    if (_rate != 1.0) setRate(_rate);
    if (_pitch != 1.0) setPitch(_pitch);
    if (_equalizer != Equalizer.flat) setEqualizer(_equalizer);
    if (_silenceConfig.mode != SilenceSkipMode.disabled) {
      setSilenceSkip(_silenceConfig);
    }
    if (_visualizerEnabled) setVisualizerEnabled(true);
    if (_preamp != 0.0) setPreamp(_preamp);
    if (_replayGain.enabled) setReplayGain(_replayGain);
    if (_balance != 0.0) setBalance(_balance);
    if (_mono) setMono(true);
    if (_crossfeed != CrossfeedMode.off) setCrossfeed(_crossfeed);
    if (_spatializerEnabled) {
      setSpatializer(enabled: true, width: _spatializerWidth);
    }
    if (_reverb.enabled) {
      setReverb(
        enabled: true,
        roomSize: _reverb.roomSize,
        damping: _reverb.damping,
        width: _reverb.width,
        wet: _reverb.wet,
        dry: _reverb.dry,
      );
    }
    if (!_limiterEnabled) setLimiterEnabled(false);
  }

  void _processTelemetryPacket(List<double> data) {
    if (data.length < 18) return;
    final l = _listener;
    if (l == null) return;

    final stateInt = data[0].round();
    final posMs = data[1].round();
    final durMs = data[2].round();
    final playing = data[3] != 0.0;
    final buffering = data[4] != 0.0;
    final completed = data[5] != 0.0;
    final vol = data[6];
    final rt = data[7];
    final pt = data[8];
    final br = data[9].round();
    final silenceMs = data[11].round();
    final bufStartMs = data[12].round();
    final bufEndMs = data[13].round();
    final bufFillPct = data[14];
    final bufStreamPct = data[15];
    final bufEof = data[16] != 0.0;

    final newState = switch (stateInt) {
      1 => PlaybackState.playing,
      2 => PlaybackState.paused,
      3 => PlaybackState.completed,
      4 => PlaybackState.buffering,
      5 => PlaybackState.error,
      6 => PlaybackState.opening,
      _ => PlaybackState.stopped,
    };

    if (_playbackState != newState) {
      _playbackState = newState;
      l.onState(newState);
    }
    if (_positionMs != posMs) {
      _positionMs = posMs;
      l.onPosition(Duration(milliseconds: posMs));
    }
    if (_durationMs != durMs && durMs >= 0) {
      _durationMs = durMs;
      l.onDuration(Duration(milliseconds: durMs));
    }
    if (_isPlaying != playing) {
      _isPlaying = playing;
      l.onPlaying(playing);
    }
    if (_isBuffering != buffering) {
      _isBuffering = buffering;
      l.onBuffering(buffering);
    }
    if (_isCompleted != completed) {
      _isCompleted = completed;
      l.onCompleted(completed);
    }
    if ((_volume - vol).abs() > 1e-4) {
      _volume = vol;
      l.onVolume(vol);
    }
    if ((_rate - rt).abs() > 1e-4) {
      _rate = rt;
      l.onRate(rt);
    }
    if ((_pitch - pt).abs() > 1e-4) {
      _pitch = pt;
      l.onPitch(pt);
    }
    if (_bitrate != br && br > 0) {
      _bitrate = br;
      l.onBitrate(br);
    }
    if (_silenceSavedMs != silenceMs) {
      _silenceSavedMs = silenceMs;
      l.onSilenceSaved(Duration(milliseconds: silenceMs));
    }

    l.onBufferedRange(
      BufferedRange(
        start: Duration(milliseconds: bufStartMs),
        end: Duration(milliseconds: bufEndMs),
        duration: Duration(milliseconds: _durationMs),
        fillPercentage: bufFillPct,
        percentage: bufStreamPct,
        isBuffering: buffering,
        isEof: bufEof,
      ),
    );

    if (_visualizerEnabled && data.length >= 32) {
      l.onVisualizer(
        VisualizerData(
          bands: data.sublist(18, 28),
          rms: data[28],
          peak: data[29],
          left: data[30],
          right: data[31],
        ),
      );
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

  Future<int> _awaitWorkerOpen(WebWorkerCommand command) async {
    _ensureNotDisposed();
    await _ensureWorkerInitialized();
    _ensureNotDisposed();

    final prev = _openCompleter;
    if (prev != null && !prev.isCompleted) {
      prev.complete(MapResult.errorInvalidState);
    }
    final completer = Completer<int>();
    _openCompleter = completer;

    _worker?.postMessage(command);
    return completer.future;
  }

  @override
  Future<void> beginOpen() async {
    _ensureNotDisposed();
    await _ensureWorkerInitialized();
    _pinnedHeadSize = 0;
    _durationMs = 0;
    _positionMs = 0;
    _isPlaying = false;
    _isCompleted = false;
    _worker?.postMessage(WebWorkerCommand(type: 'beginOpen'));
  }

  @override
  Future<void> openSource(String source, {Map<String, String>? headers}) async {
    final lower = source.toLowerCase();
    final isLive = lower.contains('.m3u8') || lower.contains('/live');
    await _awaitWorkerOpen(
      WebWorkerCommand(
        type: 'openStreamEx',
        url: source,
        isLive: isLive,
        bufferCapacity: isLive ? 2 * 1024 * 1024 : 8 * 1024 * 1024,
        encodingFormat: 0,
        totalSize: isLive ? -1 : 0,
      ),
    );
  }

  @override
  Future<void> openMemory(Uint8List bytes) async {
    await _awaitWorkerOpen(
      WebWorkerCommand(
        type: 'openMemory',
        bytes: bytes.toJS,
      ),
    );
  }

  @override
  Future<void> openCustomStream({
    required int streamId,
    int? totalSize,
    required bool isSeekable,
    required Uint8List initialBytes,
  }) async {
    throw UnsupportedError('openCustomStream is only supported on native platforms');
  }

  @override
  void supplyCustomBytes({
    required int streamId,
    required int requestId,
    required Uint8List data,
    required bool isEof,
  }) {}

  @override
  void notifyCustomError({
    required int streamId,
    required int requestId,
    required String errorMessage,
  }) {}

  @override
  void notifyOpenError(int errorCode) {
    if (_isDisposed) return;
    _playbackState = PlaybackState.error;
    _listener?.onState(PlaybackState.error);
    _listener?.onError('Failed to open source', errorCode);
  }

  @override
  Future<void> play() async {
    _ensureNotDisposed();
    await _ensureWorkerInitialized();
    await _ensureAudioContextInitialized();
    _worker?.postMessage(WebWorkerCommand(type: 'play'));
    _isPlaying = true;
    _playbackState = PlaybackState.playing;
    _listener?.onPlaying(true);
    _listener?.onState(PlaybackState.playing);
  }

  @override
  Future<void> pause() async {
    _ensureNotDisposed();
    _worker?.postMessage(WebWorkerCommand(type: 'pause'));
    _isPlaying = false;
    _playbackState = PlaybackState.paused;
    _listener?.onPlaying(false);
    _listener?.onState(PlaybackState.paused);
  }

  @override
  Future<void> stop() async {
    _ensureNotDisposed();
    _worker?.postMessage(WebWorkerCommand(type: 'stop'));
    _isPlaying = false;
    _positionMs = 0;
    _playbackState = PlaybackState.stopped;
    _listener?.onPlaying(false);
    _listener?.onPosition(Duration.zero);
    _listener?.onState(PlaybackState.stopped);
  }

  @override
  Future<void> seek(Duration position) async {
    _ensureNotDisposed();
    final targetMs = position.inMilliseconds < 0 ? 0 : position.inMilliseconds;
    _positionMs = targetMs;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'seek',
        positionMs: targetMs.toDouble(),
      ),
    );
    _listener?.onPosition(Duration(milliseconds: targetMs));
    if (_isCompleted) {
      _isCompleted = false;
      _listener?.onCompleted(false);
      if (!_isPlaying) {
        _playbackState = PlaybackState.paused;
        _listener?.onState(PlaybackState.paused);
      }
    }
  }

  @override
  void setVolume(double volume) {
    _ensureNotDisposed();
    final clamped = volume.clamp(0.0, 2.0);
    _volume = clamped;
    _worker?.postMessage(WebWorkerCommand(type: 'setVolume', volume: clamped));
    _listener?.onVolume(clamped);
  }

  @override
  void setRate(double rate) {
    _ensureNotDisposed();
    final clamped = rate.clamp(0.1, 4.0);
    _rate = clamped;
    _worker?.postMessage(WebWorkerCommand(type: 'setRate', rate: clamped));
    _listener?.onRate(clamped);
  }

  @override
  void setPitch(double pitch) {
    _ensureNotDisposed();
    final clamped = pitch.clamp(0.5, 2.0);
    _pitch = clamped;
    _worker?.postMessage(WebWorkerCommand(type: 'setPitch', pitch: clamped));
    _listener?.onPitch(clamped);
  }

  @override
  void setBufferSize(int frames) {
    _ensureNotDisposed();
    final size = frames < 0 ? 0 : frames;
    _periodSize = size > 0 ? size : 2048;
    _worker?.postMessage(
      WebWorkerCommand(type: 'setBufferSize', periodSize: size),
    );
    _listener?.onBufferSize(size);
  }

  @override
  void setEqualizer(Equalizer equalizer) {
    _ensureNotDisposed();
    _equalizer = equalizer;
    final jsBands = equalizer.toList().map((g) => g.toJS).toList().toJS;
    _worker?.postMessage(
      WebWorkerCommand(type: 'setEqualizer', gainsDb: jsBands),
    );
    _listener?.onEqualizer(equalizer);
  }

  @override
  void setEqualizerBand(int band, double gainDb) {
    _ensureNotDisposed();
    _equalizer = _equalizer.withBand(band, gainDb);
    final clamped = Equalizer.clampGain(gainDb);
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setEqualizerBand',
        band: band,
        gainDb: clamped,
      ),
    );
    _listener?.onEqualizer(_equalizer);
  }

  @override
  void setSilenceSkip(SilenceSkipConfig config) {
    _ensureNotDisposed();
    final valid = config.validated();
    _silenceConfig = valid;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setSilenceSkip',
        mode: valid.mode.value,
        thresholdDb: valid.thresholdDb,
        minDurationMs: valid.minSilenceDuration.inMilliseconds,
      ),
    );
    _listener?.onSilenceConfig(valid);
  }

  @override
  void setVisualizerEnabled(bool enabled) {
    _ensureNotDisposed();
    _visualizerEnabled = enabled;
    _worker?.postMessage(
      WebWorkerCommand(type: 'setVisualizerEnabled', enabled: enabled),
    );
    _listener?.onVisualizerEnabled(enabled);
  }

  @override
  void setReplayGain(ReplayGainConfig config) {
    _ensureNotDisposed();
    _replayGain = config;
    final effectiveGain = config.enabled ? config.gainDb : 0.0;
    final effectivePeak = config.peak > 0.0 ? config.peak : 1.0;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setReplayGain',
        gainDb: effectiveGain,
        peak: effectivePeak,
        preventClipping: config.preventClipping,
      ),
    );
    _listener?.onReplayGain(config);
  }

  @override
  void setPreamp(double preampDb) {
    _ensureNotDisposed();
    final clamped = preampDb.clamp(-24.0, 24.0);
    _preamp = clamped;
    _worker?.postMessage(WebWorkerCommand(type: 'setPreamp', preampDb: clamped));
    _listener?.onPreamp(clamped);
  }

  @override
  void setBalance(double balance) {
    _ensureNotDisposed();
    final clamped = balance.clamp(-1.0, 1.0);
    _balance = clamped;
    _worker?.postMessage(WebWorkerCommand(type: 'setBalance', pan: clamped));
    _listener?.onBalance(clamped);
  }

  @override
  void setMono(bool enabled) {
    _ensureNotDisposed();
    _mono = enabled;
    _worker?.postMessage(WebWorkerCommand(type: 'setMono', enabled: enabled));
    _listener?.onMono(enabled);
  }

  @override
  void setCrossfeed(CrossfeedMode mode) {
    _ensureNotDisposed();
    _crossfeed = mode;
    _worker?.postMessage(
      WebWorkerCommand(type: 'setCrossfeed', preset: mode.index),
    );
    _listener?.onCrossfeed(mode);
  }

  @override
  void setSpatializer({required bool enabled, required double width}) {
    _ensureNotDisposed();
    final clampedWidth = width.clamp(1.0, 2.0);
    _spatializerEnabled = enabled;
    _spatializerWidth = clampedWidth;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setSpatializer',
        enabled: enabled,
        width: clampedWidth,
      ),
    );
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
    _reverb = rev;
    _worker?.postMessage(
      WebWorkerCommand(
        type: 'setReverb',
        enabled: rev.enabled,
        roomSize: rev.roomSize,
        damping: rev.damping,
        width: rev.width,
        wet: rev.wet,
        dry: rev.dry,
      ),
    );
    _listener?.onReverb(rev);
  }

  @override
  void setLimiterEnabled(bool enabled) {
    _ensureNotDisposed();
    _limiterEnabled = enabled;
    _worker?.postMessage(WebWorkerCommand(type: 'setLimiter', enabled: enabled));
    _listener?.onLimiter(enabled);
  }

  @override
  void setSpatialEnabled(bool enabled) {}

  @override
  void setSpatialListener(SpatialListener listener) {}

  @override
  void setSpatialEmitter(SpatialEmitter emitter) {}

  @override
  void setSpatialDopplerFactor(double factor) {}

  @override
  void setSpatialSpeedOfSound(double speed) {}

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
  Future<void> setDevice(String deviceId) async {
    final isAuto = deviceId.isEmpty || deviceId == 'auto';
    _currentDevice = AudioDevice(
      id: isAuto ? 'auto' : deviceId,
      name: isAuto ? 'SYSTEM DEFAULT' : deviceId,
      isAuto: isAuto,
    );
    _listener?.onDevice(_currentDevice);
  }

  @override
  AudioDevice getCurrentDevice() => _currentDevice;

  @override
  void setPauseOnDeviceChange(bool enabled) {
    _pauseOnDeviceChange = enabled;
  }

  @override
  bool getPauseOnDeviceChange() => _pauseOnDeviceChange;

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

/// Web implementation of [PlatformService].
class WebPlatformService implements PlatformService {
  @override
  Future<List<AudioDevice>> getAudioDevices() async => [AudioDevice.auto];

  @override
  Stream<List<AudioDevice>> getAudioDevicesStream() =>
      Stream.value([AudioDevice.auto]);

  @override
  List<AudioDevice> getAudioDevicesSync() => const [AudioDevice.auto];

  @override
  Future<List<AudioDevice>> getCaptureDevices() async => [AudioDevice.auto];

  @override
  List<AudioDevice> getCaptureDevicesSync() => const [AudioDevice.auto];

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
        final flags = (replayGain ? 0x01 : 0) | (waveform ? 0x02 : 0);
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
            completer.complete(
              _mapWebAnalysisResult(
                msg.analysisResult!,
                replayGain: replayGain,
                waveform: waveform,
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

  static AudioAnalysisResult _mapWebAnalysisResult(
    JSAnalysisResult res, {
    required bool replayGain,
    required bool waveform,
  }) {
    final rg = (replayGain && res.hasReplayGain)
        ? ReplayGainResult(
            gainDb: res.replayGainGainDb,
            peak: res.replayGainPeak,
            lufs: res.replayGainLufs,
          )
        : null;
    final wf = (waveform && res.waveform != null)
        ? WaveformResult(
            points: res.waveform!.toDart.map((e) => e.toDouble()).toList(),
          )
        : null;

    return AudioAnalysisResult(
      duration: Duration(milliseconds: res.durationMs.round()),
      sampleRate: res.sampleRate.round(),
      channels: res.channels.round(),
      bitrate: res.bitrate.round(),
      peak: res.peak,
      replayGain: rg,
      waveform: wf,
    );
  }

  @override
  void setLogLevel(int level) {
    for (final b in WebPlayerBackend.activeBackends) {
      b._worker?.postMessage(
        WebWorkerCommand(type: 'setLogLevel', logLevel: level),
      );
    }
  }
}

PlayerBackend createPlayerBackend([dynamic _]) => WebPlayerBackend();
PlatformService getPlatformService() => WebPlatformService();
