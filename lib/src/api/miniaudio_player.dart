import 'dart:async';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../crossfeed.dart';
import '../equalizer.dart';
import '../infinite_mix.dart';
import '../loader/custom_byte_provider.dart';
import '../reverb.dart';
import '../rust/api/player.dart' as rust;
import '../rust/api/types.dart' as rust_types;
import '../rust/frb_generated.dart';
import 'audio_analysis_result.dart';
import 'audio_device.dart';
import 'buffer.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'logger.dart';
import 'loop_mode.dart';
import 'player_exception.dart';
import 'player_models.dart';
import 'recording.dart' show DuckingConfig;
import 'silence_skip_config.dart';
import 'spatial.dart';
import 'visualizer_data.dart';

part 'audio_source.dart';
part 'player_action.dart';
part 'player_state.dart';
part 'player_stream.dart';
part 'voice.dart';

/// Ensures native Rust library is initialized before calling static methods.
Future<void> ensureRustInitialized() async {
  if (!RustLib.instance.initialized) {
    try {
      await RustLib.init(forceSameCodegenVersion: false);
    } catch (_) {
      final candidates = [
        '../rust/target/debug/libminiaudio_player.so',
        'rust/target/debug/libminiaudio_player.so',
        '../rust/target/release/libminiaudio_player.so',
        'rust/target/release/libminiaudio_player.so',
      ];
      bool loaded = false;
      for (final candidate in candidates) {
        if (File(candidate).existsSync()) {
          try {
            await RustLib.init(
              forceSameCodegenVersion: false,
              externalLibrary: ExternalLibrary.open(candidate),
            );
            loaded = true;
            break;
          } catch (_) {}
        }
      }
      if (!loaded) rethrow;
    }
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

  /// Raw native log level integer value.
  final int value;
  const MiniaudioLogLevel(this.value);

  /// Resolves a [MiniaudioLogLevel] from its raw integer [value].
  static MiniaudioLogLevel fromValue(int value) {
    for (final level in MiniaudioLogLevel.values) {
      if (level.value == value) return level;
    }
    return MiniaudioLogLevel.none;
  }
}

/// Resolves the user-facing display name for the system default audio device.
typedef DefaultDeviceDisplayNameResolver = String Function(String resolvedName);

/// Global configuration parameters for [MiniaudioPlayer] instances.
class MiniaudioPlayerGlobalConfig {
  /// The optional global log callback for intercepting or redirecting diagnostic messages.
  static MiniaudioLogCallback? onLog;

  /// The default buffer frame size for newly created player instances.
  int defaultBufferSize;

  /// The global native diagnostic logging verbosity level.
  MiniaudioLogLevel logLevel;

  /// The resolver function producing a human-readable name for system default audio devices.
  DefaultDeviceDisplayNameResolver defaultDeviceDisplayNameResolver;

  /// The prefetch buffer duration for local media files.
  Duration bufferLocalDuration;

  /// The prefetch buffer duration for remote HTTP/HTTPS network streams.
  Duration bufferNetworkDuration;

  /// The prefetch buffer duration for live unbounded streams.
  Duration bufferLiveStreamDuration;

  /// The duration of played audio preserved in the ring buffer behind the playback position for local media.
  Duration bufferBehindLocalDuration;

  /// The duration of played audio preserved in the ring buffer behind the playback position for network streams.
  Duration bufferBehindNetworkDuration;

  /// The duration of played audio preserved in the ring buffer behind the playback position for live streams.
  Duration bufferBehindLiveStreamDuration;

  /// Creates a [MiniaudioPlayerGlobalConfig] container with default options.
  MiniaudioPlayerGlobalConfig({
    this.defaultBufferSize = 0,
    this.logLevel = MiniaudioLogLevel.none,
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

  /// Resets all global configuration parameters to their clean default values.
  void reset() {
    onLog = null;
    defaultBufferSize = 0;
    logLevel = MiniaudioLogLevel.none;
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

  /// The global configuration singleton for [MiniaudioPlayer].
  static MiniaudioPlayerGlobalConfig get globalConfig => _globalConfig;

  /// Updates global configuration parameters and returns the configuration singleton.
  static MiniaudioPlayerGlobalConfig config({
    int? defaultBufferSize,
    MiniaudioLogLevel? logLevel,
    DefaultDeviceDisplayNameResolver? defaultDeviceDisplayNameResolver,
    Duration? bufferLocalDuration,
    Duration? bufferNetworkDuration,
    Duration? bufferLiveStreamDuration,
    Duration? bufferBehindLocalDuration,
    Duration? bufferBehindNetworkDuration,
    Duration? bufferBehindLiveStreamDuration,
  }) {
    if (defaultBufferSize != null) {
      _globalConfig.defaultBufferSize = defaultBufferSize;
    }
    if (logLevel != null) _globalConfig.logLevel = logLevel;
    if (defaultDeviceDisplayNameResolver != null) {
      _globalConfig.defaultDeviceDisplayNameResolver =
          defaultDeviceDisplayNameResolver;
    }
    if (bufferLocalDuration != null) {
      _globalConfig.bufferLocalDuration = bufferLocalDuration;
    }
    if (bufferNetworkDuration != null) {
      _globalConfig.bufferNetworkDuration = bufferNetworkDuration;
    }
    if (bufferLiveStreamDuration != null) {
      _globalConfig.bufferLiveStreamDuration = bufferLiveStreamDuration;
    }
    if (bufferBehindLocalDuration != null) {
      _globalConfig.bufferBehindLocalDuration = bufferBehindLocalDuration;
    }
    if (bufferBehindNetworkDuration != null) {
      _globalConfig.bufferBehindNetworkDuration = bufferBehindNetworkDuration;
    }
    if (bufferBehindLiveStreamDuration != null) {
      _globalConfig.bufferBehindLiveStreamDuration =
          bufferBehindLiveStreamDuration;
    }
    return _globalConfig;
  }

  /// Resets global audio player configuration to clean defaults.
  static void resetGlobalConfig() => _globalConfig.reset();

  /// Ensures native Rust audio player backend is initialized.
  static Future<void> ensureInitialized() async => ensureRustInitialized();

  // =========================================================================
  // System Audio Device Discovery
  // =========================================================================

  /// Synchronously scans and enumerates connected playback output audio devices on the host OS.
  ///
  /// Returns a list containing at least [AudioDevice.auto] if enumeration fails or no devices exist.
  static List<AudioDevice> getOutputDevicesSync() {
    try {
      final devs = rust.RustMiniaudioPlayer.getOutputDevicesSync();
      return devs.map(_toAudioDevice).toList();
    } catch (_) {
      return const [AudioDevice.auto];
    }
  }

  /// Asynchronously enumerates connected playback output audio devices on the host OS.
  ///
  /// Returns a list containing at least [AudioDevice.auto] if enumeration fails or no devices exist.
  static Future<List<AudioDevice>> getOutputDevices() async {
    try {
      final devs = await rust.RustMiniaudioPlayer.getOutputDevices();
      return devs.map(_toAudioDevice).toList();
    } catch (_) {
      return const [AudioDevice.auto];
    }
  }

  /// Synchronously scans and enumerates connected microphone capture devices on the host OS.
  ///
  /// Returns a list containing at least [AudioDevice.auto] if enumeration fails or no devices exist.
  static List<AudioDevice> getInputDevicesSync() {
    try {
      final devs = rust.RustMiniaudioPlayer.getInputDevicesSync();
      return devs.map(_toAudioDevice).toList();
    } catch (_) {
      return const [AudioDevice.auto];
    }
  }

  /// Asynchronously enumerates connected microphone capture devices on the host OS.
  ///
  /// Returns a list containing at least [AudioDevice.auto] if enumeration fails or no devices exist.
  static Future<List<AudioDevice>> getInputDevices() async {
    try {
      final devs = await rust.RustMiniaudioPlayer.getInputDevices();
      return devs.map(_toAudioDevice).toList();
    } catch (_) {
      return const [AudioDevice.auto];
    }
  }

  // =========================================================================
  // Acoustic Analysis
  // =========================================================================

  /// Performs offline acoustic analysis of an [AudioSource] or source object on a background worker thread.
  ///
  /// Recycles native streaming decks with circular buffering so analyzing multi-hour
  /// or infinite streams maintains strictly constant $O(1)$ memory usage.
  ///
  /// When `replayGain: false && waveform: false`, static header analysis resolves
  /// near-instantaneously (< 1 ms) without decoding audio sample frames.
  ///
  /// Parameters:
  /// - [source]: An [AudioSource], local file path [String], remote URL [String] / [Uri],
  ///   or in-memory audio bytes ([Uint8List] / `List<int>`).
  /// - [replayGain]: When `true` (default), computes ITU-R BS.1770-4 / EBU R128 integrated
  ///   loudness (LUFS) and ReplayGain adjustment relative to [targetLufs].
  /// - [waveform]: When `true` (default), extracts a normalized amplitude envelope of length
  ///   [waveformPoints] for rendering seekbars and waveform visualizations.
  /// - [metadata]: When `true` (defaults to `false`), extracts container/header metadata bytes
  ///   into [AudioAnalysisResult.metadata].
  /// - [waveformPoints]: Number of normalized peak buckets (`> 0`) to extract across the track.
  /// - [targetLufs]: Target reference loudness in LUFS (defaults to `-18.0` LUFS).
  /// - [maxAnalysisDuration]: Optional maximum duration to analyze (e.g. for live or unbounded streams).
  static Future<AudioAnalysisResult> analyzeAudio(
    Object source, {
    bool replayGain = true,
    bool waveform = true,
    bool metadata = false,
    int waveformPoints = 100,
    double targetLufs = -18.0,
    Duration? maxAnalysisDuration,
  }) async {
    await ensureRustInitialized();
    final audioSource = source is AudioSource ? source : AudioSource(source);
    final rustSource = audioSource.toRustSource();
    final rustConfig = rust_types.RustAnalysisConfig(
      replayGain: replayGain,
      waveform: waveform,
      metadata: metadata,
      waveformPoints: waveformPoints > 0 ? waveformPoints : 100,
      targetLufs: targetLufs,
      maxDurationMs: maxAnalysisDuration?.inMilliseconds,
    );
    try {
      final res = await rust.analyzeAudioSource(
        source: rustSource,
        config: rustConfig,
      );
      return _toAnalysisResult(res);
    } catch (e) {
      if (e is MiniaudioPlayerException) rethrow;
      throw MiniaudioPlayerException(e.toString());
    }
  }

  /// Performs synchronous offline acoustic analysis of a local file or in-memory audio [source].
  ///
  /// Network and streaming sources are not supported synchronously; use [analyzeAudio] instead.
  ///
  /// Parameters:
  /// - [source]: An [AudioSource], local file path [String], or in-memory audio bytes ([Uint8List]).
  /// - [replayGain]: When `true` (default), computes ITU-R BS.1770-4 / EBU R128 integrated
  ///   loudness (LUFS) and ReplayGain adjustment relative to [targetLufs].
  /// - [waveform]: When `true` (default), extracts a normalized amplitude envelope of length
  ///   [waveformPoints] for rendering seekbars and waveform visualizations.
  /// - [metadata]: When `true` (defaults to `false`), extracts container/header metadata bytes
  ///   into [AudioAnalysisResult.metadata].
  /// - [waveformPoints]: Number of normalized peak buckets (`> 0`) to extract across the track.
  /// - [targetLufs]: Target reference loudness in LUFS (defaults to `-18.0` LUFS).
  /// - [maxAnalysisDuration]: Optional maximum duration to analyze.
  static AudioAnalysisResult analyzeAudioSync(
    Object source, {
    bool replayGain = true,
    bool waveform = true,
    bool metadata = false,
    int waveformPoints = 100,
    double targetLufs = -18.0,
    Duration? maxAnalysisDuration,
  }) {
    final audioSource = source is AudioSource ? source : AudioSource(source);
    if (!audioSource.isFile && !audioSource.isMemory) {
      throw const MiniaudioPlayerException(
        'analyzeAudioSync only supports local file paths and in-memory byte sources. '
        'For network or streaming sources, use the asynchronous analyzeAudio method.',
      );
    }
    final rustSource = audioSource.toRustSource();
    final rustConfig = rust_types.RustAnalysisConfig(
      replayGain: replayGain,
      waveform: waveform,
      metadata: metadata,
      waveformPoints: waveformPoints > 0 ? waveformPoints : 100,
      targetLufs: targetLufs,
      maxDurationMs: maxAnalysisDuration?.inMilliseconds,
    );
    try {
      final res = rust.analyzeAudioSourceSync(
        source: rustSource,
        config: rustConfig,
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

  StreamSubscription<rust_types.RustPlayerEvent>? _eventSub;
  bool _isDisposed = false;

  /// Whether this player instance has been disposed.
  bool get isDisposed => _isDisposed;

  /// The monotonic counter allocating unique identifiers for queued sources.
  int _nextSourceId = 1;

  /// The lookup registry mapping unique monotonic track IDs to their [AudioSource] instances.
  final Map<int, AudioSource<T>> _sourceRegistry = {};

  /// The active [CustomByteProvider] instances keyed by stream ID.
  final Map<int, CustomByteProvider> _customProviders = {};

  /// The callback supplying more tracks when Infinite Mix triggers.
  InfiniteMixProvider<T>? _infiniteMixProvider;

  /// Action namespace executing asynchronous imperative playback and DSP controls.
  late final PlayerAction<T> action;

  /// Reactive stream namespace for observing state changes.
  late final PlayerStream<T> stream;

  /// Synchronous snapshot namespace for instant $O(1)$ state inspection.
  late final PlayerState<T> state;

  // =========================================================================
  // Constructors
  // =========================================================================

  /// Primary canonical constructor. Accepts optional initial [queue] playlist,
  /// RAM [effects], multi-matrix [outputs], capture [inputs], and [config].
  ///
  /// The optional [effectMemoryLimitMb] parameter overrides `config.effectMemoryLimitMb`
  /// when provided.
  MiniaudioPlayer({
    List<AudioSource<T>> queue = const [],
    List<AudioEffect> effects = const [],
    Set<AudioOutput>? outputs,
    Set<AudioInput> inputs = const {},
    PlayerConfig config = const PlayerConfig(),
    int? effectMemoryLimitMb,
    int? bufferSize,
    bool pauseOnDeviceChange = false,
    CrossfadeConfig? crossfadeConfig,
  }) {
    if (!RustLib.instance.initialized) {
      throw StateError(
        'MiniaudioPlayer requires initialization before instantiation. '
        'Please call `await MiniaudioPlayer.ensureInitialized();` in your '
        'main() function before creating any player instances.',
      );
    }
    MapLogger.info('Initializing MiniaudioPlayer');
    stream = PlayerStream<T>(this);
    state = PlayerState<T>(this);

    state._bufferSize = bufferSize ?? _globalConfig.defaultBufferSize;
    state._pauseOnDeviceChange = pauseOnDeviceChange;

    final int? resolvedMaxRamBytes = effectMemoryLimitMb != null
        ? effectMemoryLimitMb * 1024 * 1024
        : config.resolvedMaxRamBytes;
    state._maxRamBytes = resolvedMaxRamBytes;

    final resolvedOutputs = outputs ?? {const AudioOutput()};
    final rustOutputs = resolvedOutputs
        .map((out) => rust_types.RustAudioOutput(
              deviceId: out.deviceId,
              source: out.source.value,
            ))
        .toList();

    _rustPlayer = rust.RustMiniaudioPlayer(
      config: rust_types.RustPlayerConfig(
        bufferSizeFrames: state.bufferSize > 0 ? state.bufferSize : 1024,
        maxVoices: config.maxVoices,
        maxRamBytes: resolvedMaxRamBytes != null
            ? BigInt.from(resolvedMaxRamBytes)
            : null,
        pauseOnDeviceChange: pauseOnDeviceChange,
        bufferLocalDurationMs:
            BigInt.from(_globalConfig.bufferLocalDuration.inMilliseconds),
        bufferNetworkDurationMs:
            BigInt.from(_globalConfig.bufferNetworkDuration.inMilliseconds),
      ),
      sampleRate: 44100,
      channels: 2,
      periodSize: state.bufferSize > 0 ? state.bufferSize : 1024,
      initialOutputs: rustOutputs,
    );

    action = PlayerAction<T>(this, _rustPlayer);

    _eventSub = _rustPlayer.subscribeEvents().listen(_onRustEvent);

    if (effects.isNotEmpty) {
      action.setEffects(effects);
    }
    if (inputs.isNotEmpty) {
      action.setInputs(inputs);
    }
    if (pauseOnDeviceChange) {
      action.setPauseOnDeviceChange(true);
    }
    if (crossfadeConfig != null) {
      action.setCrossfade(crossfadeConfig);
    }
    if (queue.isNotEmpty) {
      action.setQueue(queue);
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
        state._playbackState = val;
        state._isPaused = val == PlaybackState.paused;
        state._isOpening = val == PlaybackState.opening;
        stream._playbackStateController.add(val);
      case rust_types.RustPlayerEvent_IsPlaying(:final field0):
        state._isPlaying = field0;
        stream._playingController.add(field0);
      case rust_types.RustPlayerEvent_IsBuffering(:final field0):
        state._isBuffering = field0;
        stream._bufferingController.add(field0);
      case rust_types.RustPlayerEvent_IsCompleted(:final field0):
        state._isCompleted = field0;
        stream._completedController.add(field0);
      case rust_types.RustPlayerEvent_State(:final field0):
        final p = (field0 >= 0 && field0 < EnginePhase.values.length)
            ? EnginePhase.values[field0]
            : EnginePhase.idle;
        state._phase = p;
        stream._phaseController.add(p);
      case rust_types.RustPlayerEvent_Position(:final field0):
        final pos = Duration(milliseconds: field0.toInt());
        state._position = pos;
        stream._positionController.add(pos);
      case rust_types.RustPlayerEvent_AudioInfo(:final field0):
        final durMs = field0.durationMs?.toInt();
        final dur =
            (durMs != null && durMs > 0) ? Duration(milliseconds: durMs) : null;
        final info = AudioInfo(
          duration: dur,
          sampleRate: field0.sampleRate,
          channels: field0.channels,
          bitrate: field0.bitrate,
          format: field0.format,
        );
        state._audioInfo = info;
        stream._audioInfoController.add(info);
      case rust_types.RustPlayerEvent_Buffer(:final field0):
        final b = Buffer(
          start: Duration(milliseconds: field0.startMs.toInt()),
          end: Duration(milliseconds: field0.endMs.toInt()),
          isBuffering: field0.isBuffering,
        );
        state._buffer = b;
        stream._bufferController.add(b);
      case rust_types.RustPlayerEvent_Volume(:final field0):
        state._volume = field0;
        stream._volumeController.add(field0);
      case rust_types.RustPlayerEvent_Rate(:final field0):
        state._rate = field0;
        stream._rateController.add(field0);
      case rust_types.RustPlayerEvent_Pitch(:final field0):
        state._pitch = field0;
        stream._pitchController.add(field0);
      case rust_types.RustPlayerEvent_Balance(:final field0):
        state._balance = field0;
        stream._balanceController.add(field0);
      case rust_types.RustPlayerEvent_Mono(:final field0):
        state._mono = field0;
        stream._monoController.add(field0);
      case rust_types.RustPlayerEvent_Equalizer(:final field0):
        final eq = Equalizer.fromList(
          field0.gains.toList(),
          enabled: field0.enabled,
        );
        state._equalizer = eq;
        stream._equalizerController.add(eq);
      case rust_types.RustPlayerEvent_Reverb(:final field0):
        final rev = Reverb(
          roomSize: field0.roomSize,
          damping: field0.damping,
          wet: field0.wet,
          dry: field0.dry,
          width: field0.width,
          enabled: field0.enabled,
        );
        state._reverb = rev;
        stream._reverbController.add(rev);
      case rust_types.RustPlayerEvent_Limiter(:final field0):
        state._limiterEnabled = field0;
        stream._limiterEnabledController.add(field0);
      case rust_types.RustPlayerEvent_Preamp(:final field0):
        state._preamp = field0;
        stream._preampController.add(field0);
      case rust_types.RustPlayerEvent_Crossfeed(:final field0):
        final cf = Crossfeed(
          enabled: field0.enabled,
          cutoffHz: field0.cutoffHz,
          feedDb: field0.feedDb,
        );
        state._crossfeed = cf;
        stream._crossfeedController.add(cf);
      case rust_types.RustPlayerEvent_Spatializer(:final enabled, :final width):
        state._spatializerEnabled = enabled;
        state._spatializerWidth = width;
        stream._spatializerEnabledController.add(enabled);
        stream._spatializerWidthController.add(width);
      case rust_types.RustPlayerEvent_VisualizerEnabled(:final field0):
        state._visualizerEnabled = field0;
        if (!field0) {
          state._visualizer = VisualizerData.empty();
          stream._visualizerController.add(VisualizerData.empty());
        }
        stream._visualizerEnabledController.add(field0);
      case rust_types.RustPlayerEvent_Visualizer(:final field0):
        final vis = VisualizerData(
          bands: field0.bands.toList(),
          rms: field0.rms,
          peak: field0.peak,
          left: field0.left,
          right: field0.right,
        );
        state._visualizer = vis;
        stream._visualizerController.add(vis);
      case rust_types.RustPlayerEvent_OutputDevices(:final field0):
        final list = field0.map(_toAudioDevice).toList();
        state._globalOutputDevices = list;
        stream._globalOutputDevicesController.add(list);
      case rust_types.RustPlayerEvent_InputDevices(:final field0):
        final list = field0.map(_toAudioDevice).toList();
        state._globalInputDevices = list;
        stream._globalInputDevicesController.add(list);
      case rust_types.RustPlayerEvent_PauseOnDeviceChange(:final field0):
        state._pauseOnDeviceChange = field0;
        stream._pauseOnDeviceChangeController.add(field0);
      case rust_types.RustPlayerEvent_Outputs(:final field0):
        final outs = field0
            .map((r) => AudioOutput(
                  deviceId: r.deviceId,
                  source: AudioOutputSource.fromValue(r.source),
                ))
            .toSet();
        state._outputs = Set.unmodifiable(outs);
        stream._outputsController.add(state.outputs);
      case rust_types.RustPlayerEvent_RecordingState(
          :final isRecording,
          :final source,
        ):
        state._isRecording = isRecording;
        state._recordingSource =
            isRecording ? AudioOutputSource.fromValue(source) : null;
        stream._isRecordingController.add(isRecording);
        stream._recordingSourceController.add(state.recordingSource);
      case rust_types.RustPlayerEvent_LoopMode(:final field0):
        final lm = (field0 >= 0 && field0 < LoopMode.values.length)
            ? LoopMode.values[field0]
            : LoopMode.off;
        state._loopMode = lm;
        stream._loopModeController.add(lm);
      case rust_types.RustPlayerEvent_IsShuffled(:final field0):
        state._isShuffled = field0;
        stream._isShuffledController.add(field0);
      case rust_types.RustPlayerEvent_InfiniteMix(:final field0):
        final im = InfiniteMixConfig(
          enabled: field0.enabled,
          remainingTracksThreshold: field0.remainingTracksThreshold,
        );
        state._infiniteMix = im;
        stream._infiniteMixController.add(im);
        stream._infiniteMixEnabledController.add(im.enabled);
      case rust_types.RustPlayerEvent_Inputs(:final field0):
        final inps = field0
            .map((r) => AudioInput(
                  deviceId: r.deviceId,
                  config: AudioInputConfig(
                    volume: r.config.volume,
                    ducking: r.config.ducking != null
                        ? DuckingConfig(
                            enabled: r.config.ducking!.enabled,
                            duckingDb: r.config.ducking!.duckingDb,
                            thresholdDb: r.config.ducking!.thresholdDb,
                            attackMs: r.config.ducking!.attackMs,
                            holdMs: r.config.ducking!.holdMs,
                            releaseMs: r.config.ducking!.releaseMs,
                          )
                        : null,
                    monitorDirect: r.config.monitorDirect,
                    monitorVolume: r.config.monitorVolume,
                  ),
                ))
            .toSet();
        state._inputs = Set.unmodifiable(inps);
        stream._inputsController.add(state.inputs);
      case rust_types.RustPlayerEvent_IsCrossfading(:final field0):
        state._isCrossfading = field0;
        stream._isCrossfadingController.add(field0);
      case rust_types.RustPlayerEvent_CrossfadeConfig(:final field0):
        final cfg = CrossfadeConfig(
          autoDuration: Duration(milliseconds: field0.autoDurationMs.toInt()),
          manualDuration:
              Duration(milliseconds: field0.manualDurationMs.toInt()),
          curve: field0.curve == 1
              ? CrossfadeCurve.linear
              : CrossfadeCurve.equalPower,
        );
        state._crossfadeConfig = cfg;
        stream._crossfadeConfigController.add(cfg);
      case rust_types.RustPlayerEvent_IsRecording(:final field0):
        state._isRecording = field0;
        stream._isRecordingController.add(field0);
      case rust_types.RustPlayerEvent_RecordedDuration(:final field0):
        final d = Duration(milliseconds: field0.toInt());
        state._recordedDuration = d;
        stream._recordedDurationController.add(d);
      case rust_types.RustPlayerEvent_IsDuckingActive(:final field0):
        state._isDuckingActive = field0;
        stream._isDuckingActiveController.add(field0);
      case rust_types.RustPlayerEvent_MicRmsLevel(:final field0):
        state._micRmsLevel = field0;
        stream._micRmsLevelController.add(field0);
      case rust_types.RustPlayerEvent_VoiceCompleted(:final field0):
        stream._voiceCompletedController.add(field0);
      case rust_types.RustPlayerEvent_LoadedEffects(
          :final ids,
          :final allocatedBytes
        ):
        state._loadedEffectIds = List.unmodifiable(ids);
        state._allocatedRamBytes = allocatedBytes.toInt();
        stream._loadedEffectIdsController.add(state.loadedEffectIds);
        stream._allocatedRamBytesController.add(state.allocatedRamBytes);
      case rust_types.RustPlayerEvent_ActiveVoices(:final field0):
        state._activeVoicesCount = field0;
        stream._activeVoicesCountController.add(field0);
      case rust_types.RustPlayerEvent_AudioMetadata(:final field0):
        final meta = field0.bytes.isEmpty ? null : AudioMetadata(bytes: field0.bytes);
        state._metadata = meta;
        stream._metadataController.add(meta);
      case rust_types.RustPlayerEvent_MetadataEnabled(:final field0):
        state._metadataEnabled = field0;
        if (!field0) {
          state._metadata = null;
          stream._metadataController.add(null);
        }
        stream._metadataEnabledController.add(field0);
      case rust_types.RustPlayerEvent_SilenceConfig(:final field0):
        final sc = SilenceSkipConfig(
          enabled: field0.enabled,
          thresholdDb: field0.thresholdDb,
          minSilenceDuration:
              Duration(milliseconds: field0.minSilenceDurationMs),
          padding: Duration(milliseconds: field0.paddingMs),
          mode: SilenceSkipMode.fromValue(field0.mode),
        );
        state._silenceConfig = sc;
        state._skipSilence = field0.enabled;
        state._silenceSkipMode = sc.mode;
        stream._silenceConfigController.add(sc);
        stream._skipSilenceController.add(field0.enabled);
      case rust_types.RustPlayerEvent_SilenceSaved(:final field0):
        final d = Duration(milliseconds: field0.toInt());
        state._silenceSavedDuration = d;
        stream._silenceSavedDurationController.add(d);
      case rust_types.RustPlayerEvent_ReplayGain(:final field0):
        final rg = ReplayGainConfig(
          gainDb: field0.gainDb,
          peak: field0.peak,
        );
        state._replayGain = rg;
        stream._replayGainController.add(rg);
      case rust_types.RustPlayerEvent_ReplayGainMode(:final field0):
        final mode = (field0 >= 0 && field0 < ReplayGainMode.values.length)
            ? ReplayGainMode.values[field0]
            : ReplayGainMode.track;
        state._replayGainMode = mode;
        stream._replayGainModeController.add(mode);
      case rust_types.RustPlayerEvent_DefaultReplayGain(:final field0):
        state._defaultReplayGain = field0;
        stream._defaultReplayGainController.add(field0);
      case rust_types.RustPlayerEvent_BufferSize(:final field0):
        state._bufferSize = field0;
        stream._bufferSizeController.add(field0);
      case rust_types.RustPlayerEvent_CurrentIndex(:final field0):
        final idx = field0 >= 0 ? field0 : null;
        state._currentIndex = idx;
        stream._currentIndexController.add(idx);
        state._currentItem = idx != null && idx >= 0 && idx < state.queue.length
            ? state.queue[idx]
            : null;
        final curSource = state.currentItem;
        stream._currentItemController.add(curSource);
      case rust_types.RustPlayerEvent_Queue(:final queue, :final currentIndex):
        final reconciled = <AudioSource<T>>[];
        for (var i = 0; i < queue.length; i++) {
          final id = queue[i].toInt();
          final match = _sourceRegistry[id];
          if (match != null) {
            reconciled.add(match);
          }
        }
        state._queue = List.unmodifiable(reconciled);
        final idx = currentIndex >= 0 && currentIndex < state.queue.length
            ? currentIndex
            : null;
        state._currentIndex = idx;
        state._currentItem = idx != null ? state.queue[idx] : null;
        stream._currentIndexController.add(idx);
        stream._queueController.add(state.queue);
        stream._currentItemController.add(state.currentItem);
      case rust_types.RustPlayerEvent_DartReadRequest(:final field0):
        _onDartReadRequest(field0);
      case rust_types.RustPlayerEvent_NeedMoreTracks(
          :final currentTrackId,
          :final remainingTracks,
        ):
        _onNeedMoreTracks(currentTrackId.toInt(), remainingTracks);
      case rust_types.RustPlayerEvent_Error(:final message, :final code):
        stream._errorsController
            .add(MiniaudioPlayerException(message, errorCode: code));
    }
  }

  void _onDartReadRequest(rust_types.RustDartReadRequest req) async {
    final provider = _customProviders[req.streamId];
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

  /// Handles native Infinite Mix queue replenishment requests.
  void _onNeedMoreTracks(int currentTrackId, int remainingTracks) async {
    if (_infiniteMixProvider != null) {
      try {
        final threshold = state.infiniteMix.remainingTracksThreshold;
        final countToFetch = (threshold - remainingTracks).clamp(1, 10);
        final more = await _infiniteMixProvider!(countToFetch);
        if (more.isNotEmpty && !_isDisposed) {
          action.append(more);
        }
      } catch (_) {}
    }
  }

  /// Verifies that this player instance has not been disposed, throwing [StateError] otherwise.
  void _ensureNotDisposed() {
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
    state._metadata = null;
    state._audioInfo = null;
    _eventSub?.cancel();
    _eventSub = null;
    try {
      _rustPlayer.dispose();
    } catch (_) {}
    for (final p in _customProviders.values) {
      try {
        await p.close();
      } catch (_) {}
    }
    _customProviders.clear();
    await stream.dispose();
  }

  // Model Mappers
  static AudioDevice _toAudioDevice(rust_types.RustAudioDevice dev) {
    final isAuto = dev.isAuto || dev.id == 'AUTO' || dev.id == 'auto';
    return AudioDevice(
      id: isAuto ? 'AUTO' : dev.id,
      name: dev.name,
      isAuto: isAuto,
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
    final md = res.hasMetadata && res.metadata != null
        ? AudioMetadata(bytes: res.metadata!.bytes)
        : null;
    final info = AudioInfo(
      duration: res.audioInfo.durationMs != null
          ? Duration(milliseconds: res.audioInfo.durationMs!.toInt())
          : null,
      sampleRate: res.audioInfo.sampleRate,
      channels: res.audioInfo.channels,
      bitrate: res.audioInfo.bitrate,
      format: res.audioInfo.format,
    );
    return AudioAnalysisResult(
      audioInfo: info,
      peak: res.peakAmplitude,
      replayGain: rg,
      waveform: wf,
      metadata: md,
    );
  }
}
