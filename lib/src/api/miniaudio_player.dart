import 'dart:async';
import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/custom_byte_provider.dart';
import '../reverb.dart';
import '../rust/api/player.dart' as rust;
import '../rust/api/types.dart' as rust_types;
import '../rust/frb_generated.dart';
import 'audio_analysis_result.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'logger.dart';
import 'loop_mode.dart';
import 'need_more_tracks_event.dart';
import 'player_action.dart';
import 'player_exception.dart';
import 'player_models.dart';
import 'player_state.dart';
import 'player_stream.dart';
import 'silence_skip_config.dart';
import 'visualizer_data.dart';

/// Ensures native Rust library is initialized before calling static methods.
Future<void> ensureRustInitialized() async {
  if (!RustLib.instance.initialized) {
    await RustLib.init();
  }
}

/// Supported audio file extensions natively decoded by [MiniaudioPlayer].
const List<String> miniAudioPlayerSupportedExtensions = [
  'mp3',
  'wav',
  'flac',
  'ogg',
  'opus',
  'aif',
  'aiff',
  'aifc',
  'w64',
  'rf64',
  'bwf',
  'rifx',
  'mp2',
  'mp1',
  'oga',
  'aac',
  'm4a',
  'webm',
  'mkv',
  'mka',
  'caf',
];

/// Log verbosity levels for native miniaudio and sonic engine diagnostics.
enum MiniaudioLogLevel {
  /// Disables all native logging output (`0`).
  none(0),

  /// Logs only unrecoverable or critical native errors (`1`).
  error(1),

  /// Logs errors and non-fatal warnings (`2`).
  warning(2),

  /// Logs high-level lifecycle events (device init, open, seek, stop) (`3`).
  info(3),

  /// Logs verbose frame-level, buffer, and streaming diagnostics (`4`).
  debug(4),

  /// Logs maximum trace-level diagnostics (`5`).
  verbose(5);

  final int value;
  const MiniaudioLogLevel(this.value);

  static MiniaudioLogLevel fromValue(int value) {
    for (final level in MiniaudioLogLevel.values) {
      if (level.value == value) return level;
    }
    return MiniaudioLogLevel.none;
  }
}

/// Resolves the user-facing display name for the system default audio device.
typedef DefaultDeviceDisplayNameResolver = String Function(String resolvedName);

/// Optional resolver for loading Flutter bundle assets.
typedef AssetBytesLoader = Future<Uint8List> Function(String assetKey);

/// Global configuration parameters for [MiniaudioPlayer] instances.
class MiniaudioPlayerGlobalConfig {
  static MiniaudioLogCallback? onLog;
  static AssetBytesLoader? assetLoader;

  int defaultBufferSize;
  MiniaudioLogLevel logLevel;
  AudioDevice defaultAudioDevice;
  DefaultDeviceDisplayNameResolver defaultDeviceDisplayNameResolver;
  Duration bufferLocalDuration;
  Duration bufferNetworkDuration;
  Duration bufferLiveStreamDuration;
  Duration bufferBehindLocalDuration;
  Duration bufferBehindNetworkDuration;
  Duration bufferBehindLiveStreamDuration;

  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
    this.defaultAudioDevice = AudioDevice.auto,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    this.bufferLocalDuration = const Duration(seconds: 30),
    this.bufferNetworkDuration = const Duration(seconds: 30),
    this.bufferLiveStreamDuration = const Duration(seconds: 15),
    this.bufferBehindLocalDuration = const Duration(seconds: 10),
    this.bufferBehindNetworkDuration = const Duration(seconds: 15),
    this.bufferBehindLiveStreamDuration = const Duration(seconds: 5),
  }) : defaultDeviceDisplayNameResolver = defaultDeviceDisplayNameResolver ??
            _defaultDeviceDisplayNameResolver;

  static String _defaultDeviceDisplayNameResolver(String resolvedName) {
    final clean = resolvedName.trim();
    return clean.isEmpty ? 'System Default' : 'System Default ($clean)';
  }

  void reset() {
    onLog = null;
    assetLoader = null;
    defaultBufferSize = 0;
    logLevel = MiniaudioLogLevel.none;
    defaultAudioDevice = AudioDevice.auto;
    defaultDeviceDisplayNameResolver = _defaultDeviceDisplayNameResolver;
    bufferLocalDuration = const Duration(seconds: 30);
    bufferNetworkDuration = const Duration(seconds: 30);
    bufferLiveStreamDuration = const Duration(seconds: 15);
    bufferBehindLocalDuration = const Duration(seconds: 10);
    bufferBehindNetworkDuration = const Duration(seconds: 15);
    bufferBehindLiveStreamDuration = const Duration(seconds: 5);
  }
}

/// Master Miniaudio Player Coordinator orchestrating streaming music decks,
/// polyphonic RAM sound effects, multi-destination output matrix, and microphone sidechain.
///
/// Features 3 consolidated, orthogonal namespaces:
/// - `player.action` : Asynchronous imperative commands.
/// - `player.state`  : $O(1)$ lock-free synchronous state snapshot (stream-backed).
/// - `player.stream` : Reactive broadcast streams for UI bindings.
class MiniaudioPlayer<T> {
  static final MiniaudioPlayerGlobalConfig _globalConfig =
      MiniaudioPlayerGlobalConfig();

  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;
  static MiniaudioPlayerGlobalConfig config({
    int? defaultBufferSize,
    MiniaudioLogLevel? logLevel,
    AudioDevice? defaultAudioDevice,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    Duration? bufferBehindLocalDuration,
    Duration? bufferBehindNetworkDuration,
    Duration? bufferBehindLiveStreamDuration,
  }) {
    if (defaultBufferSize != null) _globalConfig.defaultBufferSize = defaultBufferSize;
    if (logLevel != null) _globalConfig.logLevel = logLevel;
    if (defaultAudioDevice != null) _globalConfig.defaultAudioDevice = defaultAudioDevice;
    if (defaultDeviceDisplayNameResolver != null) {
      _globalConfig.defaultDeviceDisplayNameResolver = defaultDeviceDisplayNameResolver;
    }
    if (bufferLocalDuration != null) _globalConfig.bufferLocalDuration = bufferLocalDuration;
    if (bufferNetworkDuration != null) _globalConfig.bufferNetworkDuration = bufferNetworkDuration;
    if (bufferLiveStreamDuration != null) _globalConfig.bufferLiveStreamDuration = bufferLiveStreamDuration;
    if (bufferBehindLocalDuration != null) _globalConfig.bufferBehindLocalDuration = bufferBehindLocalDuration;
    if (bufferBehindNetworkDuration != null) _globalConfig.bufferBehindNetworkDuration = bufferBehindNetworkDuration;
    if (bufferBehindLiveStreamDuration != null) _globalConfig.bufferBehindLiveStreamDuration = bufferBehindLiveStreamDuration;
    return _globalConfig;
  }

  /// Resets global audio engine configuration to clean defaults.
  static void resetGlobalConfig() => _globalConfig.reset();

  /// Ensures native Rust audio engine backend is initialized.
  static Future<void> ensureInitialized() async => ensureRustInitialized();

  // =========================================================================
  // Acoustic Analysis
  // =========================================================================

  /// Performs offline acoustic analysis of an audio file on a background worker thread.
  static Future<AudioAnalysisResult> analyzeAudio(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    await ensureRustInitialized();
    try {
      final res = await rust.analyzeAudioFile(
        path: filePath,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: BigInt.from(waveformPoints),
        targetLufs: targetLufs,
      );
      return _toAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      throw MiniaudioPlayerException(e.toString());
    }
  }

  static AudioAnalysisResult analyzeAudioSync(
    String filePath, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) {
    try {
      final res = rust.analyzeAudioFileSync(
        path: filePath,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: BigInt.from(waveformPoints),
        targetLufs: targetLufs,
      );
      return _toAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      throw MiniaudioPlayerException(e.toString());
    }
  }

  static Future<AudioAnalysisResult> analyzeAudioMemory(
    Uint8List bytes, {
    bool replayGain = true,
    bool waveform = true,
    int waveformPoints = 100,
    double targetLufs = -18.0,
  }) async {
    await ensureRustInitialized();
    try {
      final res = await rust.analyzeAudioMemory(
        data: bytes,
        replayGain: replayGain,
        waveform: waveform,
        waveformPoints: BigInt.from(waveformPoints),
        targetLufs: targetLufs,
      );
      return _toAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      throw MiniaudioPlayerException(e.toString());
    }
  }

  /// Sets global native diagnostic log level.
  static void setLogLevel(MiniaudioLogLevel level) {
    try {
      rust.setLogLevel(level: level.value);
    } catch (_) {}
  }

  // =========================================================================
  // Instance State & Core Fields
  // =========================================================================

  late final rust.RustMiniaudioPlayer _rustPlayer;
  rust.RustMiniaudioPlayer get rustPlayer => _rustPlayer;

  StreamSubscription<rust_types.RustPlayerEvent>? _eventSub;
  bool _isDisposed = false;

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  List<AudioSource<T>> shadowQueue = [];
  final Map<int, CustomByteProvider> customProviders = {};

  final Set<AudioOutput> _activeOutputs = {const AudioOutput.speaker()};
  Set<AudioOutput> get activeOutputsSet => _activeOutputs;

  bool infiniteMixEnabled = false;
  InfiniteMixProvider<T>? infiniteMixProvider;

  /// Action namespace executing asynchronous imperative playback and DSP controls.
  late final PlayerAction<T> action;

  /// Reactive stream namespace for observing state changes.
  late final PlayerStream<T> stream;

  /// Synchronous snapshot namespace for instant $O(1)$ state inspection.
  late final PlayerState<T> state;

  // =========================================================================
  // Constructors
  // =========================================================================

  /// Primary canonical constructor. Accepts optional initial [source] playlist,
  /// RAM [effects], multi-matrix [outputs], capture [inputs], and [config].
  MiniaudioPlayer({
    List<AudioSource<T>> source = const [],
    List<AudioEffect> effects = const [],
    Set<AudioOutput>? outputs,
    Set<AudioInput> inputs = const {},
    PlayerConfig config = const PlayerConfig(),
    int? bufferSize,
    AudioDevice? defaultAudioDevice,
    bool pauseOnDeviceChange = false,
    CrossfadeConfig? crossfadeConfig,
  }) {
    MapLogger.info('Initializing MiniaudioPlayer');
    action = PlayerAction<T>(this);
    stream = PlayerStream<T>();
    state = PlayerState<T>(this);

    state.bufferSize = bufferSize ?? _globalConfig.defaultBufferSize;
    state.audioDevice = defaultAudioDevice ?? _globalConfig.defaultAudioDevice;
    state.pauseOnDeviceChange = pauseOnDeviceChange;

    _rustPlayer = rust.RustMiniaudioPlayer(
      config: rust_types.RustPlayerConfig(
        bufferSizeFrames: state.bufferSize > 0 ? state.bufferSize : 1024,
        maxVoices: config.maxVoices,
        maxRamBytes: BigInt.from(config.maxRamBytes),
        pauseOnDeviceChange: pauseOnDeviceChange,
        bufferLocalDurationMs:
            BigInt.from(_globalConfig.bufferLocalDuration.inMilliseconds),
        bufferNetworkDurationMs:
            BigInt.from(_globalConfig.bufferNetworkDuration.inMilliseconds),
      ),
      sampleRate: 44100,
      channels: 2,
      periodSize: state.bufferSize > 0 ? state.bufferSize : 1024,
      playbackDeviceId: state.audioDevice.isAuto ? null : state.audioDevice.id,
    );

    _eventSub = _rustPlayer.subscribeEvents().listen(_onRustEvent);

    final resolvedOutputs = outputs ?? {const AudioOutput.speaker()};
    _activeOutputs
      ..clear()
      ..addAll(resolvedOutputs);
    state.outputs = Set.of(_activeOutputs);

    if (effects.isNotEmpty) {
      action.preloadEffects(effects);
    }
    if (outputs != null &&
        !(outputs.length == 1 && outputs.first == const AudioOutput.speaker())) {
      action.configureOutputs(outputs);
    }
    for (final input in inputs) {
      action.addInput(input);
    }
    if (pauseOnDeviceChange) {
      action.setPauseOnDeviceChange(true);
    }
    if (crossfadeConfig != null) {
      action.setCrossfade(crossfadeConfig);
    }
    if (source.isNotEmpty) {
      action.open(source, autoPlay: false);
    }
  }

  // =========================================================================
  // Native Rust Event Dispatcher (Fine-Grained Active Stream Ingestion)
  // =========================================================================

  void _onRustEvent(rust_types.RustPlayerEvent event) {
    if (_isDisposed) return;
    switch (event) {
      case rust_types.RustPlayerEvent_PlaybackState(:final field0):
        final val = switch (field0) {
          1 => PlaybackState.playing,
          2 => PlaybackState.paused,
          3 => PlaybackState.completed,
          4 => PlaybackState.buffering,
          5 => PlaybackState.error,
          6 => PlaybackState.opening,
          _ => PlaybackState.stopped,
        };
        state.playbackState = val;
        state.isPaused = val == PlaybackState.paused;
        state.isOpening = val == PlaybackState.opening;
        stream.playbackStateController.add(val);
      case rust_types.RustPlayerEvent_IsPlaying(:final field0):
        state.isPlaying = field0;
        stream.playingController.add(field0);
        if (field0) {
          checkInfiniteMix();
        }
      case rust_types.RustPlayerEvent_IsBuffering(:final field0):
        state.isBuffering = field0;
        stream.bufferingController.add(field0);
      case rust_types.RustPlayerEvent_IsCompleted(:final field0):
        state.isCompleted = field0;
        stream.completedController.add(field0);
      case rust_types.RustPlayerEvent_State(:final field0):
        final p = (field0 >= 0 && field0 < EnginePhase.values.length)
            ? EnginePhase.values[field0]
            : EnginePhase.idle;
        state.phase = p;
        stream.phaseController.add(p);
      case rust_types.RustPlayerEvent_Position(:final field0):
        final pos = Duration(milliseconds: field0.toInt());
        state.position = pos;
        stream.positionController.add(pos);
      case rust_types.RustPlayerEvent_Duration(:final field0):
        final durMs = field0.toInt();
        // durMs <= 0 represents an uninitialized track or a live / unbounded stream.
        // durMs > 0 represents a finite track (even very short ones like 15ms-100ms sound effects).
        final dur = durMs > 0 ? Duration(milliseconds: durMs) : null;
        state.duration = dur;
        stream.durationController.add(dur);
      case rust_types.RustPlayerEvent_BufferedRange(:final field0):
        final br = BufferedRange(
          start: Duration(milliseconds: field0.startMs.toInt()),
          end: Duration(milliseconds: field0.endMs.toInt()),
          isBuffering: field0.isBuffering,
        );
        state.bufferedRange = br;
        state.bufferedPosition = Duration(milliseconds: field0.endMs.toInt());
        state.bufferedPercentage = (state.duration?.inMilliseconds ?? 0) > 0
            ? (field0.endMs.toDouble() / state.duration!.inMilliseconds)
            : 0.0;
        stream.bufferedRangeController.add(br);
        stream.bufferedPositionController.add(state.bufferedPosition);
        stream.bufferedPercentageController.add(state.bufferedPercentage);
      case rust_types.RustPlayerEvent_Volume(:final field0):
        state.volume = field0;
        stream.volumeController.add(field0);
      case rust_types.RustPlayerEvent_Rate(:final field0):
        state.rate = field0;
        stream.rateController.add(field0);
      case rust_types.RustPlayerEvent_Pitch(:final field0):
        state.pitch = field0;
        stream.pitchController.add(field0);
      case rust_types.RustPlayerEvent_Balance(:final field0):
        state.balance = field0;
        stream.balanceController.add(field0);
      case rust_types.RustPlayerEvent_Mono(:final field0):
        state.mono = field0;
        stream.monoController.add(field0);
      case rust_types.RustPlayerEvent_Equalizer(:final field0):
        final eq = Equalizer.fromList(field0.gains.toList());
        state.equalizer = eq;
        stream.equalizerController.add(eq);
      case rust_types.RustPlayerEvent_Reverb(:final field0):
        final rev = Reverb(
          roomSize: field0.roomSize,
          damping: field0.damping,
          wet: field0.wet,
          dry: field0.dry,
          width: field0.width,
          enabled: field0.enabled,
        );
        state.reverb = rev;
        stream.reverbController.add(rev);
      case rust_types.RustPlayerEvent_Limiter(:final field0):
        state.limiterEnabled = field0;
        stream.limiterEnabledController.add(field0);
      case rust_types.RustPlayerEvent_Preamp(:final field0):
        state.preamp = field0;
        stream.preampController.add(field0);
      case rust_types.RustPlayerEvent_Crossfeed(:final field0):
        final cm = (field0 >= 0 && field0 < CrossfeedMode.values.length)
            ? CrossfeedMode.values[field0]
            : CrossfeedMode.off;
        state.crossfeed = cm;
        stream.crossfeedController.add(cm);
      case rust_types.RustPlayerEvent_Spatializer(:final enabled, :final width):
        state.spatializerEnabled = enabled;
        state.spatializerWidth = width;
        stream.spatializerEnabledController.add(enabled);
        stream.spatializerWidthController.add(width);
      case rust_types.RustPlayerEvent_VisualizerEnabled(:final field0):
        state.visualizerEnabled = field0;
        if (!field0) {
          state.visualizer = VisualizerData.empty();
          stream.visualizerController.add(VisualizerData.empty());
        }
        stream.visualizerEnabledController.add(field0);
      case rust_types.RustPlayerEvent_Visualizer(:final field0):
        final vis = VisualizerData(
          bands: field0.bands.toList(),
          rms: field0.rms,
          peak: field0.peak,
          left: field0.left,
          right: field0.right,
        );
        state.visualizer = vis;
        stream.visualizerController.add(vis);
      case rust_types.RustPlayerEvent_OutputDevices(:final field0):
        final list = field0.map(_toAudioDevice).toList();
        state.globalOutputDevices = list;
        stream.globalOutputDevicesController.add(list);
      case rust_types.RustPlayerEvent_InputDevices(:final field0):
        final list = field0.map(_toAudioDevice).toList();
        state.globalInputDevices = list;
        stream.globalInputDevicesController.add(list);
      case rust_types.RustPlayerEvent_PauseOnDeviceChange(:final field0):
        state.pauseOnDeviceChange = field0;
        stream.pauseOnDeviceChangeController.add(field0);
      case rust_types.RustPlayerEvent_CueVolume(:final field0):
        state.cueVolume = field0;
        stream.cueVolumeController.add(field0);
      case rust_types.RustPlayerEvent_CueSource(:final field0):
        final cs = CueSource.fromValue(field0);
        state.cueSource = cs;
        stream.cueSourceController.add(cs);
      case rust_types.RustPlayerEvent_LoopMode(:final field0):
        final lm = (field0 >= 0 && field0 < LoopMode.values.length)
            ? LoopMode.values[field0]
            : LoopMode.off;
        state.loopMode = lm;
        stream.loopModeController.add(lm);
      case rust_types.RustPlayerEvent_IsShuffled(:final field0):
        state.isShuffled = field0;
        stream.isShuffledController.add(field0);
      case rust_types.RustPlayerEvent_MicrophoneEnabled(:final field0):
        state.isMicrophoneEnabled = field0;
        stream.isMicrophoneEnabledController.add(field0);
      case rust_types.RustPlayerEvent_MicVolume(:final field0):
        state.micVolume = field0;
        stream.micVolumeController.add(field0);
      case rust_types.RustPlayerEvent_DirectMonitoringEnabled(:final field0):
        state.isDirectMonitoringEnabled = field0;
        stream.isDirectMonitoringEnabledController.add(field0);
      case rust_types.RustPlayerEvent_IsCrossfading(:final field0):
        state.isCrossfading = field0;
        stream.isCrossfadingController.add(field0);
      case rust_types.RustPlayerEvent_CrossfadeConfig(:final field0):
        final cfg = CrossfadeConfig(
          autoDuration: Duration(milliseconds: field0.autoDurationMs.toInt()),
          manualDuration: Duration(milliseconds: field0.manualDurationMs.toInt()),
          curve: field0.curve == 1 ? CrossfadeCurve.linear : CrossfadeCurve.equalPower,
        );
        state.crossfadeConfig = cfg;
        stream.crossfadeConfigController.add(cfg);
      case rust_types.RustPlayerEvent_IsRecording(:final field0):
        state.isRecording = field0;
        stream.isRecordingController.add(field0);
      case rust_types.RustPlayerEvent_RecordedDuration(:final field0):
        final d = Duration(milliseconds: field0.toInt());
        state.recordedDuration = d;
        stream.recordedDurationController.add(d);
      case rust_types.RustPlayerEvent_IsDuckingActive(:final field0):
        state.isDuckingActive = field0;
        stream.isDuckingActiveController.add(field0);
      case rust_types.RustPlayerEvent_MicRmsLevel(:final field0):
        state.micRmsLevel = field0;
        stream.micRmsLevelController.add(field0);
      case rust_types.RustPlayerEvent_VoiceCompleted(:final field0):
        stream.voiceCompletedController.add(field0);
      case rust_types.RustPlayerEvent_MetaBytes(:final field0):
        final mb = field0.isEmpty ? null : Uint8List.fromList(field0);
        state.metaBytes = mb;
        stream.metaBytesController.add(mb);
      case rust_types.RustPlayerEvent_MetaBytesEnabled(:final field0):
        state.metaBytesEnabled = field0;
        if (!field0) {
          state.metaBytes = null;
          stream.metaBytesController.add(null);
        }
        stream.metaBytesEnabledController.add(field0);
      case rust_types.RustPlayerEvent_SilenceConfig(:final field0):
        final sc = SilenceSkipConfig(
          thresholdDb: field0.thresholdDb,
          minSilenceDuration: Duration(milliseconds: field0.minSilenceDurationMs),
          padding: Duration(milliseconds: field0.paddingMs),
          mode: SilenceSkipMode.fromValue(field0.mode),
        );
        state.silenceConfig = sc;
        state.skipSilence = field0.enabled;
        state.silenceSkipMode = sc.mode;
        stream.silenceConfigController.add(sc);
        stream.skipSilenceController.add(field0.enabled);
      case rust_types.RustPlayerEvent_SilenceSaved(:final field0):
        final d = Duration(milliseconds: field0.toInt());
        state.silenceSavedDuration = d;
        stream.silenceSavedDurationController.add(d);
      case rust_types.RustPlayerEvent_ReplayGain(:final field0):
        final rg = ReplayGainConfig(
          gainDb: field0.gainDb,
          peak: field0.peak,
          preventClipping: field0.preventClipping,
          enabled: field0.enabled,
        );
        state.replayGain = rg;
        stream.replayGainController.add(rg);
      case rust_types.RustPlayerEvent_BufferSize(:final field0):
        state.bufferSize = field0;
        stream.bufferSizeController.add(field0);
      case rust_types.RustPlayerEvent_Bitrate(:final field0):
        state.audioBitrate = field0;
        stream.audioBitrateController.add(field0);
      case rust_types.RustPlayerEvent_Device(:final field0):
        final dev = _toAudioDevice(field0);
        state.audioDevice = dev;
        stream.audioDeviceController.add(dev);
      case rust_types.RustPlayerEvent_CurrentIndex(:final field0):
        state.currentIndex = field0;
        stream.currentIndexController.add(field0);
        final curSource = state.currentItem;
        stream.currentItemController.add(curSource);
        checkInfiniteMix();
      case rust_types.RustPlayerEvent_Queue(:final field0):
        final reconciled = <AudioSource<T>>[];
        for (var i = 0; i < field0.length; i++) {
          final rs = field0[i];
          final match = shadowQueue.cast<AudioSource<T>?>().firstWhere(
                (s) => s != null && s.id != null && s.id == rs.id,
                orElse: () => shadowQueue.cast<AudioSource<T>?>().firstWhere(
                  (s) =>
                      s != null &&
                      ((s is UriAudioSource &&
                              (s as UriAudioSource).sourceString ==
                                  rs.source) ||
                          s.sourceKey == rs.source),
                  orElse: () => null,
                ),
              );
          if (match != null) {
            reconciled.add(match);
          } else {
            reconciled.add(AudioSource<T>(rs.source, id: rs.id));
          }
        }
        state.queue = reconciled;
        shadowQueue = List.of(reconciled);
        stream.queueController.add(reconciled);
        stream.currentItemController.add(state.currentItem);
        checkInfiniteMix();
      case rust_types.RustPlayerEvent_DartReadRequest(:final field0):
        _onDartReadRequest(field0);
      case rust_types.RustPlayerEvent_Error(:final message, :final code):
        stream.errorsController.add(MiniaudioPlayerException(message, errorCode: code));
    }
  }

  void _onDartReadRequest(rust_types.RustDartReadRequest req) async {
    final provider = customProviders[req.streamId];
    if (provider != null) {
      try {
        final bytes = await provider.readBytes(req.offset.toInt(), req.length);
        final isEof = bytes.isEmpty ||
            (provider.totalBytes != null &&
                (req.offset.toInt() + bytes.length >= provider.totalBytes!));
        if (!_isDisposed) {
          _rustPlayer.respondDartReadRequest(
            requestId: req.requestId,
            bytes: bytes,
            isEof: isEof,
          );
        }
      } catch (e) {
        if (!_isDisposed) {
          _rustPlayer.respondDartReadRequest(
            requestId: req.requestId,
            bytes: Uint8List(0),
            isEof: true,
          );
        }
      }
    }
  }

  void checkInfiniteMix() async {
    if (!infiniteMixEnabled || !state.isPlaying) return;
    final curIdx = state.currentIndex;
    final remaining = shadowQueue.length - 1 - (curIdx >= 0 ? curIdx : 0);
    if (remaining < 2 && !stream.needMoreTracksController.isClosed) {
      stream.needMoreTracksController.add(
        NeedMoreTracksEvent(
          currentTrackId: curIdx >= 0 ? curIdx : 0,
          remainingTracks: remaining < 0 ? 0 : remaining,
        ),
      );
      if (infiniteMixProvider != null) {
        try {
          final more = await infiniteMixProvider!(
            (2 - remaining).clamp(1, 10),
          );
          if (more.isNotEmpty && !_isDisposed) {
            action.append(more);
          }
        } catch (_) {}
      }
    }
  }

  void ensureNotDisposed() {
    if (_isDisposed) {
      throw StateError('MiniaudioPlayer instance has been disposed');
    }
  }

  // =========================================================================
  // Lifecycle Disposal
  // =========================================================================

  /// Closes the player, terminates background watcher loops, and disposes native resources.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    MapLogger.info('Disposing MiniaudioPlayer instance');
    state.metaBytes = null;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      _rustPlayer.dispose();
    } catch (_) {}
    for (final p in customProviders.values) {
      try {
        await p.close();
      } catch (_) {}
    }
    customProviders.clear();
    await stream.dispose();
  }

  // Model Mappers
  static AudioDevice _toAudioDevice(rust_types.RustAudioDevice dev) {
    return AudioDevice(
      id: dev.id,
      name: dev.name,
      isAuto: dev.isDefault,
      effectiveId: dev.effectiveId,
    );
  }

  static AudioAnalysisResult _toAnalysisResult(
    rust_types.RustAudioAnalysisResult res,
  ) {
    final rg = res.hasReplayGain
        ? ReplayGainResult(
            gainDb: res.replayGainDb,
            peak: res.peakAmplitude,
            lufs: res.integratedLufs,
          )
        : null;
    final wf = res.hasWaveform && res.waveformPeaks.isNotEmpty
        ? WaveformResult(
            points: res.waveformPeaks.map((e) => e.toDouble()).toList(),
          )
        : null;
    return AudioAnalysisResult(
      duration: Duration(milliseconds: res.durationMs.toInt()),
      sampleRate: res.sampleRate,
      channels: res.channels,
      bitrate: res.bitrate,
      peak: res.peakAmplitude,
      replayGain: rg,
      waveform: wf,
    );
  }
}
