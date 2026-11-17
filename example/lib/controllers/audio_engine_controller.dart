import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../models/audio_track.dart';
import '../models/mock_data.dart';

class _DomainNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// Studio Master Console Engine Controller powered directly by [MiniaudioPlayer].
///
/// Manages dual-deck audio threads, automated crossfades, reorderable playlist queue,
/// DSP effects (Equalizer, Reverb, Limiter, Silence Skipping, Crossfeed), multi-output matrix,
/// multi-capture input routing with ducking, and live recording.
class AudioEngineController extends ChangeNotifier {
  final MiniaudioPlayer<AudioTrack> engine = MiniaudioPlayer<AudioTrack>(
    config: PlayerConfig(
      crossfade: CrossfadeConfig(
        autoDuration: const Duration(seconds: 5),
        manualDuration: const Duration(milliseconds: 100),
        curve: CrossfadeCurve.equalPower,
      ),
    ),
  );

  // Scoped domain notifiers so changing one control only rebuilds its owning UI widget.
  final _DomainNotifier _trackSelectionNotifier = _DomainNotifier();
  final _DomainNotifier _waveformNotifier = _DomainNotifier();
  final _DomainNotifier _transportControlsNotifier = _DomainNotifier();
  final _DomainNotifier _recordingNotifier = _DomainNotifier();
  final _DomainNotifier _queueNotifier = _DomainNotifier();
  final _DomainNotifier _routingNotifier = _DomainNotifier();
  final _DomainNotifier _visualizerControlsNotifier = _DomainNotifier();
  final _DomainNotifier _replayGainNotifier = _DomainNotifier();
  final _DomainNotifier _limiterNotifier = _DomainNotifier();
  final _DomainNotifier _monoNotifier = _DomainNotifier();
  final _DomainNotifier _preampNotifier = _DomainNotifier();
  final _DomainNotifier _balanceNotifier = _DomainNotifier();
  final _DomainNotifier _pauseOnDeviceChangeNotifier = _DomainNotifier();
  final _DomainNotifier _metadataEnabledNotifier = _DomainNotifier();
  final _DomainNotifier _silenceNotifier = _DomainNotifier();
  final _DomainNotifier _crossfeedNotifier = _DomainNotifier();
  final _DomainNotifier _spatializerNotifier = _DomainNotifier();
  final _DomainNotifier _reverbNotifier = _DomainNotifier();
  final _DomainNotifier _equalizerNotifier = _DomainNotifier();

  late final List<_DomainNotifier> _domainNotifiers = [
    _trackSelectionNotifier,
    _waveformNotifier,
    _transportControlsNotifier,
    _recordingNotifier,
    _queueNotifier,
    _routingNotifier,
    _visualizerControlsNotifier,
    _replayGainNotifier,
    _limiterNotifier,
    _monoNotifier,
    _preampNotifier,
    _balanceNotifier,
    _pauseOnDeviceChangeNotifier,
    _metadataEnabledNotifier,
    _silenceNotifier,
    _crossfeedNotifier,
    _spatializerNotifier,
    _reverbNotifier,
    _equalizerNotifier,
  ];

  Listenable get trackSelectionListenable => _trackSelectionNotifier;
  Listenable get waveformListenable => _waveformNotifier;
  Listenable get transportControlsListenable => _transportControlsNotifier;
  Listenable get recordingListenable => _recordingNotifier;
  Listenable get queueListenable => _queueNotifier;
  Listenable get routingListenable => _routingNotifier;
  Listenable get visualizerControlsListenable => _visualizerControlsNotifier;
  Listenable get replayGainListenable => _replayGainNotifier;
  Listenable get limiterListenable => _limiterNotifier;
  Listenable get monoListenable => _monoNotifier;
  Listenable get preampListenable => _preampNotifier;
  Listenable get balanceListenable => _balanceNotifier;
  Listenable get pauseOnDeviceChangeListenable => _pauseOnDeviceChangeNotifier;
  Listenable get metadataEnabledListenable => _metadataEnabledNotifier;
  Listenable get silenceListenable => _silenceNotifier;
  Listenable get crossfeedListenable => _crossfeedNotifier;
  Listenable get spatializerListenable => _spatializerNotifier;
  Listenable get reverbListenable => _reverbNotifier;
  Listenable get equalizerListenable => _equalizerNotifier;

  final Set<String> _inFlightRpcs = {};
  final Map<String, Future<void> Function()> _pendingRpcs = {};

  bool _isRpcActive(String key) =>
      _inFlightRpcs.contains(key) || _pendingRpcs.containsKey(key);

  void _notifyDomain([_DomainNotifier? domain]) {
    if (_isDisposed) return;
    domain?.notify();
    if (hasListeners) {
      super.notifyListeners();
    }
  }

  /// Serializes high-frequency RPC updates per [key], dropping intermediate
  /// superseded values while guaranteeing the latest value is dispatched.
  Future<void> _coalesceRpc(
    String key,
    Future<void> Function() send, {
    VoidCallback? onSettled,
  }) async {
    if (_inFlightRpcs.contains(key)) {
      _pendingRpcs[key] = send;
      return;
    }
    _inFlightRpcs.add(key);
    var current = send;
    try {
      while (!_isDisposed) {
        await current();
        final next = _pendingRpcs.remove(key);
        if (next == null) break;
        current = next;
      }
    } finally {
      _inFlightRpcs.remove(key);
      _pendingRpcs.remove(key);
      onSettled?.call();
    }
  }

  Future<void> _setOptimisticScalar({
    required String rpcKey,
    required _DomainNotifier domain,
    required void Function() applyOverride,
    required Future<void> Function() send,
    VoidCallback? onSettled,
  }) async {
    applyOverride();
    _notifyDomain(domain);
    await _coalesceRpc(rpcKey, send, onSettled: onSettled);
  }

  void _onStreamOverrideSync<T>({
    required String rpcKey,
    required _DomainNotifier domain,
    required T Function() readDisplayed,
    required void Function() clearOverride,
  }) {
    if (_isRpcActive(rpcKey)) return;
    final before = readDisplayed();
    clearOverride();
    if (before != readDisplayed()) {
      _notifyDomain(domain);
    } else if (hasListeners) {
      super.notifyListeners();
    }
  }

  bool _isDisposed = false;
  bool _isReady = false;
  bool _isLoadingTrack = false;
  List<AudioTrack> _cachedTracks = [];

  List<double>? _waveformPoints;
  final Map<String, List<double>> _waveformCache = {};
  List<double> get waveformPoints => _waveformPoints ?? _sinusoidalWaveform;

  static final List<double> _sinusoidalWaveform = _generateSinusoidalWaveform();

  static List<double> _generateSinusoidalWaveform({int points = 72}) {
    return List.generate(points, (i) {
      final t = i / (points - 1);
      final envelope = sin(pi * t);
      final wave =
          0.52 + 0.36 * sin(2 * pi * t * 3.5) + 0.12 * sin(2 * pi * t * 7.0);
      return (wave * (0.35 + 0.65 * envelope)).clamp(0.08, 0.98);
    });
  }

  void updateWaveformPoints(List<double> points, {String? trackId}) {
    if (points.isNotEmpty) {
      final unmod = List<double>.unmodifiable(points);
      final id = trackId ?? selectedTrack?.id;
      if (id != null) {
        _waveformCache[id] = unmod;
      }
      if (trackId == null || trackId == selectedTrack?.id) {
        if (!listEquals(_waveformPoints, unmod)) {
          _waveformPoints = unmod;
          _notifyDomain(_waveformNotifier);
        }
      }
    }
  }

  void resetWaveformToSinusoidal() {
    if (_waveformPoints != null) {
      _waveformPoints = null;
      _notifyDomain(_waveformNotifier);
    }
  }

  /// Checks whether waveform points have been cached in the engine for [trackId].
  bool hasCachedWaveform(String trackId) => _waveformCache.containsKey(trackId);

  /// Retrieves the cached waveform points for [trackId], or null if unanalyzed.
  List<double>? getCachedWaveform(String trackId) => _waveformCache[trackId];

  double? _preampOverride;
  double get preampDb => _preampOverride ?? engine.state.preamp;

  Future<void> setPreamp(double db) => _setOptimisticScalar(
    rpcKey: 'preamp',
    domain: _preampNotifier,
    applyOverride: () => _preampOverride = db,
    send: () => engine.action.setPreamp(preampDb),
    onSettled: () {
      if (_preampOverride != null && engine.state.preamp == _preampOverride) {
        _preampOverride = null;
      }
    },
  );

  bool get replayGainEnabled => engine.state.volumeNormalization;
  ReplayGainMode? _replayGainModeOverride;
  ReplayGainMode get replayGainMode =>
      _replayGainModeOverride ?? engine.state.replayGainMode;
  double get defaultReplayGain => engine.state.defaultReplayGain;

  Future<void> setReplayGainMode(ReplayGainMode mode) {
    MapLogger.info(
      '[REPLAY_GAIN:MODE] Operating mode changed to: ${mode.name.toUpperCase()}',
    );
    return _setOptimisticScalar(
      rpcKey: 'replayGainMode',
      domain: _replayGainNotifier,
      applyOverride: () => _replayGainModeOverride = mode,
      send: () =>
          engine.action.setReplayGainMode(_replayGainModeOverride ?? mode),
      onSettled: () {
        if (_replayGainModeOverride != null &&
            engine.state.replayGainMode == _replayGainModeOverride) {
          _replayGainModeOverride = null;
        }
      },
    );
  }

  Future<void> setDefaultReplayGain(double gainDb) async {
    MapLogger.info(
      '[REPLAY_GAIN:DEFAULT] Fallback target gain set to: $gainDb dB',
    );
    await engine.action.setDefaultReplayGain(gainDb);
    _notifyDomain(_replayGainNotifier);
  }

  String _selectedPreset = 'flat';
  Equalizer? _equalizerOverride;
  String _selectedReverbPreset = 'Studio';
  Reverb? _reverbOverride;
  Reverb _lastActiveReverb = Reverb.studio;

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool get isReady => _isReady;
  bool get isLoadingTrack => _isLoadingTrack;

  AudioTrack? _currentTrack;
  String? _lastNotifiedTrackId;
  List<String>? _lastNotifiedQueueIds;
  bool _lastReplayGainEnabled = false;
  bool _lastIsRecording = false;
  bool _lastIsDuckingActive = false;
  int _lastSilenceSavedTenths = -1;

  AudioTrack? get selectedTrack {
    if (_isLoadingTrack && _currentTrack != null) return _currentTrack;
    final cur = engine.state.currentItem;
    if (cur != null && cur.data != null) return cur.data;
    if (_currentTrack != null) return _currentTrack;
    if (_cachedTracks.isNotEmpty) return _cachedTracks.first;
    return null;
  }

  List<AudioTrack> get availableTracks {
    final queue = engine.state.queue;
    if (queue.isNotEmpty) {
      return queue.where((i) => i.data != null).map((i) => i.data!).toList();
    }
    return _cachedTracks;
  }

  CrossfadeConfig? _crossfadeOverride;
  CrossfadeConfig get crossfadeConfig =>
      _crossfadeOverride ?? engine.state.crossfadeConfig;
  bool get isShuffle => engine.state.isShuffled;
  bool get isLoop => engine.state.loopMode != LoopMode.off;
  LoopMode get loopMode => engine.state.loopMode;

  Equalizer get currentEqualizer =>
      _equalizerOverride ?? engine.state.equalizer;
  bool get equalizerEnabled => currentEqualizer.enabled;
  String get selectedPreset => _selectedPreset;

  Reverb get currentReverb {
    if (_reverbOverride != null) return _reverbOverride!;
    final rev = engine.state.reverb;
    if (rev == Reverb.off) {
      return _lastActiveReverb.copyWith(enabled: false);
    }
    return rev;
  }

  String get selectedReverbPreset => _selectedReverbPreset;
  double get reverbRoomSize => currentReverb.roomSize;
  double get reverbDamping => currentReverb.damping;
  double get reverbWidth => currentReverb.width;
  double get reverbWet => currentReverb.wet;
  double get reverbDry => currentReverb.dry;
  double get reverbWetDry => currentReverb.wet;
  bool get reverbEnabled => currentReverb.enabled;

  Crossfeed? _crossfeedOverride;
  Crossfeed get crossfeed => _crossfeedOverride ?? engine.state.crossfeed;
  bool? _spatializerEnabledOverride;
  double? _spatializerWidthOverride;
  double get spatializerWidth =>
      _spatializerWidthOverride ?? engine.state.spatializerWidth;
  bool get spatializerEnabled =>
      _spatializerEnabledOverride ?? engine.state.spatializerEnabled;

  double? _stereoBalanceOverride;
  double get stereoBalance => _stereoBalanceOverride ?? engine.state.balance;

  bool? _monoOverride;
  bool get monoDownmix => _monoOverride ?? engine.state.mono;

  bool? _limiterOverride;
  bool get limiterEnabled => _limiterOverride ?? engine.state.limiterEnabled;

  SilenceSkipMode _silenceMode = SilenceSkipMode.all;
  SilenceSkipConfig? _silenceConfigOverride;

  SilenceSkipConfig get _effectiveSilenceConfig =>
      _silenceConfigOverride ?? engine.state.silenceConfig;
  bool get silenceEnabled =>
      _effectiveSilenceConfig.mode != SilenceSkipMode.disabled;
  SilenceSkipMode get silenceMode =>
      _effectiveSilenceConfig.mode != SilenceSkipMode.disabled
      ? _effectiveSilenceConfig.mode
      : _silenceMode;
  double get silenceThresholdDb => _effectiveSilenceConfig.thresholdDb;
  int get minSilenceDurationMs =>
      _effectiveSilenceConfig.minSilenceDuration.inMilliseconds;
  int get silencePaddingMs => _effectiveSilenceConfig.padding.inMilliseconds;
  Duration get silenceSavedDuration => engine.state.silenceSavedDuration;

  bool? _visualizerEnabledOverride;
  bool get visualizerEnabled =>
      _visualizerEnabledOverride ?? engine.state.visualizerEnabled;

  AudioOutputSource? _visualizerSourceOverride;
  AudioOutputSource get visualizerSource =>
      _visualizerSourceOverride ?? engine.state.visualizerSource;

  bool? _metadataEnabledOverride;
  bool get metadataEnabled =>
      _metadataEnabledOverride ?? engine.state.metadataEnabled;

  int get allocatedRamBytes => engine.state.allocatedRamBytes;
  List<String> get loadedEffectIds => engine.state.loadedEffectIds;
  int get activeVoicesCount => engine.state.activeVoicesCount;

  double? _volumeOverride;
  double get volume => _volumeOverride ?? engine.state.volume;

  double? _rateOverride;
  double get rate => _rateOverride ?? engine.state.rate;

  double? _pitchOverride;
  double get pitch => _pitchOverride ?? engine.state.pitch;

  // --- Output and Input Routing Matrix ---
  List<AudioDevice> get audioDevices => engine.state.globalOutputDevices;
  List<AudioDevice> get inputDevices => engine.state.globalInputDevices;
  Set<AudioOutput> get outputs => engine.state.outputs;
  Set<AudioInput> get inputs => engine.state.inputs;
  final Map<String, AudioInputConfig> _inputConfigs = {};

  AudioInputConfig getInputConfig(String deviceId) =>
      _inputConfigs[deviceId] ?? const AudioInputConfig();

  bool? _pauseOnDeviceChangeOverride;
  bool get pauseOnDeviceChange =>
      _pauseOnDeviceChangeOverride ?? engine.state.pauseOnDeviceChange;

  // --- Live Recording State ---
  bool get isRecording => engine.state.isRecording;
  Duration get recordedDuration => engine.state.recordedDuration;
  AudioFileFormat _recordingFormat = AudioFileFormat.wav;
  AudioFileFormat get recordingFormat => _recordingFormat;
  AudioOutputSource _recordingSource = AudioOutputSource.all;
  AudioOutputSource get recordingSource => _recordingSource;
  RecordingResult? _lastRecordingResult;
  RecordingResult? get lastRecordingResult => _lastRecordingResult;

  void setRecordingFormat(AudioFileFormat fmt) {
    if (_recordingFormat == fmt) return;
    _recordingFormat = fmt;
    _notifyDomain(_recordingNotifier);
  }

  void setRecordingSource(AudioOutputSource src) {
    if (_recordingSource == src) return;
    _recordingSource = src;
    _notifyDomain(_recordingNotifier);
  }

  Future<void> startRecording({String? customPath}) async {
    final FileSystem fs = kIsWeb ? MemoryFileSystem() : const LocalFileSystem();
    final Directory tempDir = await fs.systemTempDirectory.createTemp(
      "miniaudio_player_example_",
    );
    final File archivo = tempDir.childFile(
      'studio_recording_${DateTime.now().millisecondsSinceEpoch}.${_recordingFormat.name}',
    );

    await engine.action.startRecording(
      archivo.path,
      format: _recordingFormat,
      source: _recordingSource,
    );
    _notifyDomain(_recordingNotifier);
  }

  Future<RecordingResult> stopRecording() async {
    final res = await engine.action.stopRecording();
    _lastRecordingResult = res;
    _notifyDomain(_recordingNotifier);
    return res;
  }

  Future<void> init() async {
    _cachedTracks = await MockData.loadTracks();
    if (_isDisposed) return;

    _lastReplayGainEnabled = engine.state.volumeNormalization;
    _lastIsRecording = engine.state.isRecording;
    _lastIsDuckingActive = engine.state.isDuckingActive;
    _lastSilenceSavedTenths =
        engine.state.silenceSavedDuration.inMilliseconds ~/ 100;
    _bindSubscriptions();

    _isReady = true;
    _notifyDomain(_trackSelectionNotifier);
    _queueNotifier.notify();

    if (_cachedTracks.isNotEmpty) {
      final items = _cachedTracks
          .map((t) => t.source.withData<AudioTrack>(t))
          .toList();
      try {
        await engine.action.setQueue(items);
      } catch (_) {}
      if (_isDisposed) return;
    }

    try {
      await engine.action.setMetadataEnabled(true);
      await engine.action.setVisualizerEnabled(true);
      await engine.action.setLimiter(true);
      await engine.action.setReverb(Reverb.off);
      await engine.action.setCrossfade(
        CrossfadeConfig(
          autoDuration: const Duration(seconds: 5),
          manualDuration: const Duration(milliseconds: 100),
          curve: CrossfadeCurve.equalPower,
        ),
      );
    } catch (_) {}
    if (_isDisposed) return;

    // Load sample effects in the background so the console can mount immediately
    unawaited(loadSampleEffects());
    _notifyDomain();
  }

  static bool _crossfadeEquals(CrossfadeConfig a, CrossfadeConfig b) =>
      a.curve == b.curve &&
      a.autoDuration == b.autoDuration &&
      a.manualDuration == b.manualDuration;

  static bool _silenceConfigEquals(SilenceSkipConfig a, SilenceSkipConfig b) =>
      a.enabled == b.enabled &&
      a.mode == b.mode &&
      a.thresholdDb == b.thresholdDb &&
      a.minSilenceDuration == b.minSilenceDuration &&
      a.padding == b.padding;

  void _bindSubscriptions() {
    _subscriptions.add(
      engine.stream.currentItem.listen((item) {
        final prevWaveform = _waveformPoints;
        if (item?.data != null && item!.data is AudioTrack) {
          final track = item.data as AudioTrack;
          _currentTrack = track;
          _waveformPoints = _waveformCache[track.id];
        }
        final curTrackId = selectedTrack?.id;
        if (curTrackId != _lastNotifiedTrackId) {
          _lastNotifiedTrackId = curTrackId;
          _notifyDomain(_trackSelectionNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
        if (!listEquals(prevWaveform, _waveformPoints)) {
          _notifyDomain(_waveformNotifier);
        }
      }),
    );
    _subscriptions.add(
      engine.stream.currentIndex.listen((_) => _notifyDomain()),
    );
    _subscriptions.add(
      engine.stream.queue.listen((items) {
        final ids = items
            .map((i) => i.data?.id ?? i.id?.toString() ?? '')
            .toList(growable: false);
        if (!listEquals(_lastNotifiedQueueIds, ids)) {
          _lastNotifiedQueueIds = ids;
          _notifyDomain(_queueNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(engine.stream.isShuffled.listen((_) => _notifyDomain()));
    _subscriptions.add(engine.stream.loopMode.listen((_) => _notifyDomain()));
    _subscriptions.add(
      engine.stream.crossfadeConfig.listen((_) {
        if (_isRpcActive('crossfade')) return;
        final before = crossfadeConfig;
        _crossfadeOverride = null;
        if (!_crossfadeEquals(before, crossfadeConfig)) {
          _notifyDomain(_queueNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.playbackState.listen((_) => _notifyDomain()),
    );
    _subscriptions.add(
      engine.stream.spatializerWidth.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'spatializer',
          domain: _spatializerNotifier,
          readDisplayed: () => spatializerWidth,
          clearOverride: () => _spatializerWidthOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.spatializerEnabled.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'spatializer',
          domain: _spatializerNotifier,
          readDisplayed: () => spatializerEnabled,
          clearOverride: () => _spatializerEnabledOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.visualizerEnabled.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'visualizerEnabled',
          domain: _visualizerControlsNotifier,
          readDisplayed: () => visualizerEnabled,
          clearOverride: () => _visualizerEnabledOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.visualizerSource.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'visualizerSource',
          domain: _visualizerControlsNotifier,
          readDisplayed: () => visualizerSource,
          clearOverride: () => _visualizerSourceOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.metadataEnabled.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'metadataEnabled',
          domain: _metadataEnabledNotifier,
          readDisplayed: () => metadataEnabled,
          clearOverride: () => _metadataEnabledOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.pauseOnDeviceChange.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'pauseOnDeviceChange',
          domain: _pauseOnDeviceChangeNotifier,
          readDisplayed: () => pauseOnDeviceChange,
          clearOverride: () => _pauseOnDeviceChangeOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.silenceConfig.listen((cfg) {
        if (cfg.mode != SilenceSkipMode.disabled) {
          _silenceMode = cfg.mode;
        }
        if (_isRpcActive('silence')) return;
        final prevEnabled = silenceEnabled;
        final prevMode = silenceMode;
        final prevThresh = silenceThresholdDb;
        final prevMinMs = minSilenceDurationMs;
        final prevPadMs = silencePaddingMs;
        _silenceConfigOverride = null;
        if (prevEnabled != silenceEnabled ||
            prevMode != silenceMode ||
            prevThresh != silenceThresholdDb ||
            prevMinMs != minSilenceDurationMs ||
            prevPadMs != silencePaddingMs) {
          _notifyDomain(_silenceNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.mono.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'mono',
          domain: _monoNotifier,
          readDisplayed: () => monoDownmix,
          clearOverride: () => _monoOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.limiterEnabled.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'limiter',
          domain: _limiterNotifier,
          readDisplayed: () => limiterEnabled,
          clearOverride: () => _limiterOverride = null,
        );
      }),
    );
    _subscriptions.add(engine.stream.metadata.listen((_) => _notifyDomain()));
    _subscriptions.add(
      engine.stream.volume.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'volume',
          domain: _transportControlsNotifier,
          readDisplayed: () => volume,
          clearOverride: () => _volumeOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.rate.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'rate',
          domain: _transportControlsNotifier,
          readDisplayed: () => rate,
          clearOverride: () => _rateOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.pitch.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'pitch',
          domain: _transportControlsNotifier,
          readDisplayed: () => pitch,
          clearOverride: () => _pitchOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.equalizer.listen((eq) {
        if (_isRpcActive('equalizer')) return;
        final prevEq = currentEqualizer;
        final prevPreset = _selectedPreset;
        _equalizerOverride = null;
        _selectedPreset = _detectPreset(eq) ?? 'custom';
        if (prevEq != currentEqualizer || prevPreset != _selectedPreset) {
          _notifyDomain(_equalizerNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.reverb.listen((rev) {
        if (_isRpcActive('reverb')) return;
        final prevRev = currentReverb;
        final prevPreset = _selectedReverbPreset;
        _reverbOverride = null;
        if (rev != Reverb.off) {
          _lastActiveReverb = rev.copyWith(enabled: true);
        }
        _selectedReverbPreset =
            _detectReverbPreset(_lastActiveReverb) ?? 'Custom';
        if (prevRev != currentReverb || prevPreset != _selectedReverbPreset) {
          _notifyDomain(_reverbNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.preamp.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'preamp',
          domain: _preampNotifier,
          readDisplayed: () => preampDb,
          clearOverride: () => _preampOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.replayGain.listen((_) {
        if (engine.state.volumeNormalization != _lastReplayGainEnabled) {
          _lastReplayGainEnabled = engine.state.volumeNormalization;
          _notifyDomain(_replayGainNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.replayGainMode.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'replayGainMode',
          domain: _replayGainNotifier,
          readDisplayed: () => replayGainMode,
          clearOverride: () => _replayGainModeOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.crossfeed.listen((_) {
        _onStreamOverrideSync(
          rpcKey: 'crossfeed',
          domain: _crossfeedNotifier,
          readDisplayed: () => crossfeed,
          clearOverride: () => _crossfeedOverride = null,
        );
      }),
    );
    _subscriptions.add(
      engine.stream.silenceSavedDuration.listen((saved) {
        final tenths = saved.inMilliseconds ~/ 100;
        if (silenceEnabled && tenths != _lastSilenceSavedTenths) {
          _lastSilenceSavedTenths = tenths;
          _notifyDomain(_silenceNotifier);
        } else {
          _lastSilenceSavedTenths = tenths;
          if (hasListeners) super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(engine.stream.outputs.listen((_) => _notifyDomain()));
    _subscriptions.add(engine.stream.inputs.listen((_) => _notifyDomain()));
    _subscriptions.add(
      engine.stream.isRecording.listen((rec) {
        if (rec != _lastIsRecording) {
          _lastIsRecording = rec;
          _notifyDomain(_recordingNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.isDuckingActive.listen((ducking) {
        if (ducking != _lastIsDuckingActive) {
          _lastIsDuckingActive = ducking;
          _notifyDomain(_routingNotifier);
        } else if (hasListeners) {
          super.notifyListeners();
        }
      }),
    );
    _subscriptions.add(
      engine.stream.globalOutputDevices.listen((_) => _notifyDomain()),
    );
    _subscriptions.add(
      engine.stream.globalInputDevices.listen((_) => _notifyDomain()),
    );
  }

  // --- Multi-Destination Output Management ---
  Future<void> toggleOutput(
    AudioDevice device, {
    AudioOutputSource source = AudioOutputSource.all,
  }) async {
    final curOutputs = Set<AudioOutput>.of(engine.state.outputs);
    final exists = curOutputs.any((o) => o.deviceId == device.id);
    if (exists) {
      curOutputs.removeWhere((o) => o.deviceId == device.id);
    } else {
      curOutputs.add(AudioOutput(deviceId: device.id, source: source));
    }
    await engine.action.setOutputs(curOutputs);
    _notifyDomain(_routingNotifier);
  }

  Future<void> setOutputSource(
    String deviceId,
    AudioOutputSource source,
  ) async {
    final curOutputs = engine.state.outputs.map((o) {
      if (o.deviceId == deviceId) {
        return AudioOutput(deviceId: o.deviceId, source: source);
      }
      return o;
    }).toSet();
    await engine.action.setOutputs(curOutputs);
    _notifyDomain(_routingNotifier);
  }

  // --- Multi-Capture Input Routing Management ---
  Future<void> toggleInput(AudioDevice device) async {
    final curInputs = Set<AudioInput>.of(engine.state.inputs);
    final exists = curInputs.any((i) => i.deviceId == device.id);
    if (exists) {
      curInputs.removeWhere((i) => i.deviceId == device.id);
    } else {
      final config = getInputConfig(device.id);
      curInputs.add(AudioInput(deviceId: device.id, config: config));
    }
    await engine.action.setInputs(curInputs);
    _notifyDomain(_routingNotifier);
  }

  Future<void> configureInputDevice(
    String deviceId,
    AudioInputConfig config,
  ) async {
    _inputConfigs[deviceId] = config;
    if (engine.state.inputs.any((i) => i.deviceId == deviceId)) {
      await engine.action.configureInput(config, deviceId: deviceId);
    }
    _notifyDomain(_routingNotifier);
  }

  // --- Equalizer ---
  static String? _detectPreset(Equalizer eq) {
    final normalized = eq.copyWith(enabled: true);
    if (normalized == Equalizer.flat) return 'flat';
    if (normalized == Equalizer.rock) return 'rock';
    if (normalized == Equalizer.pop) return 'pop';
    if (normalized == Equalizer.jazz) return 'jazz';
    if (normalized == Equalizer.classical) return 'classical';
    if (normalized == Equalizer.bassBoost) return 'bassBoost';
    return null;
  }

  Future<void> _applyEqualizer(Equalizer target) => _setOptimisticScalar(
    rpcKey: 'equalizer',
    domain: _equalizerNotifier,
    applyOverride: () {
      _equalizerOverride = target;
      _selectedPreset = _detectPreset(target) ?? 'custom';
    },
    send: () => engine.action.setEqualizer(_equalizerOverride ?? target),
    onSettled: () {
      if (_equalizerOverride != null &&
          engine.state.equalizer == _equalizerOverride) {
        _equalizerOverride = null;
      }
    },
  );

  Future<void> setEqualizerEnabled(bool enabled) async {
    await _applyEqualizer(currentEqualizer.copyWith(enabled: enabled));
  }

  Future<void> setEqualizerPreset(String presetKey) async {
    final Equalizer eq;
    switch (presetKey) {
      case 'rock':
        eq = Equalizer.rock;
        break;
      case 'pop':
        eq = Equalizer.pop;
        break;
      case 'jazz':
        eq = Equalizer.jazz;
        break;
      case 'classical':
        eq = Equalizer.classical;
        break;
      case 'bassBoost':
        eq = Equalizer.bassBoost;
        break;
      case 'flat':
      default:
        eq = Equalizer.flat;
        break;
    }
    await _applyEqualizer(eq);
  }

  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    final list = currentEqualizer.toList();
    if (bandIndex >= 0 && bandIndex < list.length) {
      list[bandIndex] = gainDb;
      await _applyEqualizer(
        Equalizer.fromList(list, enabled: currentEqualizer.enabled),
      );
    }
  }

  // --- Reverb ---
  static String? _detectReverbPreset(Reverb rev) {
    for (final entry in Reverb.presets.entries) {
      if (entry.key == 'Off') continue;
      if (entry.value == rev) return entry.key;
    }
    return null;
  }

  Future<void> _applyReverb(Reverb target) => _setOptimisticScalar(
    rpcKey: 'reverb',
    domain: _reverbNotifier,
    applyOverride: () {
      final activeView = target.enabled
          ? target
          : (target == Reverb.off
                ? _lastActiveReverb
                : target.copyWith(enabled: true));
      if (target != Reverb.off) {
        _lastActiveReverb = activeView;
      }
      _selectedReverbPreset = _detectReverbPreset(activeView) ?? 'Custom';
      _reverbOverride = target.enabled
          ? target
          : activeView.copyWith(enabled: false);
    },
    send: () {
      final rev = _reverbOverride ?? target;
      return engine.action.setReverb(rev.enabled ? rev : Reverb.off);
    },
    onSettled: () {
      final rev = _reverbOverride;
      if (rev != null &&
          (engine.state.reverb == rev ||
              (!rev.enabled && engine.state.reverb == Reverb.off))) {
        _reverbOverride = null;
      }
    },
  );

  Future<void> toggleReverb(bool enabled) async {
    await _applyReverb(currentReverb.copyWith(enabled: enabled));
  }

  Future<void> setReverbPreset(String name) async {
    final preset = Reverb.presets[name] ?? Reverb.off;
    await _applyReverb(preset);
  }

  Future<void> setReverbParams({
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
    bool? enabled,
  }) async {
    await _applyReverb(
      currentReverb.copyWith(
        enabled: enabled ?? true,
        roomSize: roomSize,
        damping: damping,
        width: width,
        wet: wet,
        dry: dry,
      ),
    );
  }

  // --- Track Selection & Queue Navigation ---
  int _trackSelectionEpoch = 0;

  Future<void> selectTrack(AudioTrack track, {bool autoPlay = false}) async {
    final currentEpoch = ++_trackSelectionEpoch;
    final prevWaveform = _waveformPoints;
    _isLoadingTrack = true;
    _currentTrack = track;
    _lastNotifiedTrackId = track.id;
    _waveformPoints = _waveformCache[track.id];
    _notifyDomain(_trackSelectionNotifier);
    if (!listEquals(prevWaveform, _waveformPoints)) {
      _notifyDomain(_waveformNotifier);
    }

    try {
      final queue = engine.state.queue;
      final idx = queue.indexWhere((item) => item.data?.id == track.id);
      if (currentEpoch != _trackSelectionEpoch) return;

      if (idx != -1) {
        await engine.action.play(position: idx);
      } else {
        final item = track.source.withData<AudioTrack>(track);
        if (currentEpoch != _trackSelectionEpoch) return;
        await engine.action.insertNext(item);
        if (currentEpoch != _trackSelectionEpoch) return;
        await engine.action.next();
        if (autoPlay) {
          if (currentEpoch != _trackSelectionEpoch) return;
          await engine.action.play();
        }
      }
    } catch (e) {
      debugPrint('Error selecting track in engine: $e');
    } finally {
      if (currentEpoch == _trackSelectionEpoch) {
        _isLoadingTrack = false;
        _notifyDomain(_trackSelectionNotifier);
      }
    }
  }

  Future<void> addTrack(AudioTrack track) async {
    _cachedTracks = [..._cachedTracks, track];
    final item = track.source.withData<AudioTrack>(track);
    await engine.action.append([item]);
    await engine.action.play(position: engine.state.queue.length - 1);
    _notifyDomain(_queueNotifier);
  }

  Future<void> reorderTrack(int oldIndex, int newIndex) async {
    await engine.action.reorder(oldIndex, newIndex);
    _notifyDomain(_queueNotifier);
  }

  Future<void> toggleShuffle() async {
    await engine.action.setShuffle(!engine.state.isShuffled);
    _notifyDomain();
  }

  Future<void> toggleLoop() async {
    final nextMode = engine.state.loopMode == LoopMode.off
        ? LoopMode.all
        : engine.state.loopMode == LoopMode.all
        ? LoopMode.one
        : LoopMode.off;
    await engine.action.setLoopMode(nextMode);
    _notifyDomain();
  }

  Future<void> nextTrack() async {
    _currentTrack = null;
    resetWaveformToSinusoidal();
    try {
      await engine.action.next();
    } catch (e) {
      debugPrint('Error skipping to next track: $e');
    }
    _notifyDomain(_trackSelectionNotifier);
  }

  Future<void> previousTrack() async {
    _currentTrack = null;
    resetWaveformToSinusoidal();
    try {
      await engine.action.previous();
    } catch (e) {
      debugPrint('Error skipping to previous track: $e');
    }
    _notifyDomain(_trackSelectionNotifier);
  }

  // --- Crossfade Configuration ---
  Future<void> _applyCrossfade(CrossfadeConfig target) => _setOptimisticScalar(
    rpcKey: 'crossfade',
    domain: _queueNotifier,
    applyOverride: () => _crossfadeOverride = target,
    send: () => engine.action.setCrossfade(_crossfadeOverride ?? target),
    onSettled: () {
      if (_crossfadeOverride != null &&
          _crossfadeEquals(engine.state.crossfadeConfig, _crossfadeOverride!)) {
        _crossfadeOverride = null;
      }
    },
  );

  Future<void> setCrossfadeCurve(CrossfadeCurve curve) =>
      _applyCrossfade(crossfadeConfig.copyWith(curve: curve));

  Future<void> setCrossfadeDuration(Duration duration) =>
      _applyCrossfade(crossfadeConfig.copyWith(autoDuration: duration));

  Future<void> setManualCrossfadeDuration(Duration duration) =>
      _applyCrossfade(crossfadeConfig.copyWith(manualDuration: duration));

  // --- Crossfeed Controls ---
  Future<void> setCrossfeed(Crossfeed cf) => _setOptimisticScalar(
    rpcKey: 'crossfeed',
    domain: _crossfeedNotifier,
    applyOverride: () => _crossfeedOverride = cf,
    send: () => engine.action.setCrossfeed(_crossfeedOverride ?? cf),
    onSettled: () {
      if (_crossfeedOverride != null &&
          engine.state.crossfeed == _crossfeedOverride) {
        _crossfeedOverride = null;
      }
    },
  );

  Future<void> toggleCrossfeed(bool enabled) =>
      setCrossfeed(crossfeed.copyWith(enabled: enabled));

  Future<void> setCrossfeedCutoff(double cutoffHz) =>
      setCrossfeed(crossfeed.copyWith(cutoffHz: cutoffHz));

  Future<void> setCrossfeedFeed(double feedDb) =>
      setCrossfeed(crossfeed.copyWith(feedDb: feedDb));

  // --- Spatializer, Balance, Mono, Limiter ---
  Future<void> setSpatializerEnabled(bool enabled) => _setOptimisticScalar(
    rpcKey: 'spatializer',
    domain: _spatializerNotifier,
    applyOverride: () => _spatializerEnabledOverride = enabled,
    send: () => engine.action.setSpatializer(
      enabled: spatializerEnabled,
      width: spatializerWidth,
    ),
    onSettled: () {
      if (_spatializerEnabledOverride != null &&
          engine.state.spatializerEnabled == _spatializerEnabledOverride) {
        _spatializerEnabledOverride = null;
      }
    },
  );

  Future<void> setSpatializerWidth(double width) => _setOptimisticScalar(
    rpcKey: 'spatializer',
    domain: _spatializerNotifier,
    applyOverride: () => _spatializerWidthOverride = width,
    send: () => engine.action.setSpatializer(
      enabled: spatializerEnabled,
      width: spatializerWidth,
    ),
    onSettled: () {
      if (_spatializerWidthOverride != null &&
          engine.state.spatializerWidth == _spatializerWidthOverride) {
        _spatializerWidthOverride = null;
      }
    },
  );

  Future<void> setStereoBalance(double balance) => _setOptimisticScalar(
    rpcKey: 'balance',
    domain: _balanceNotifier,
    applyOverride: () => _stereoBalanceOverride = balance,
    send: () => engine.action.setBalance(stereoBalance),
    onSettled: () {
      if (_stereoBalanceOverride != null &&
          engine.state.balance == _stereoBalanceOverride) {
        _stereoBalanceOverride = null;
      }
    },
  );

  Future<void> setMonoDownmix(bool enabled) => _setOptimisticScalar(
    rpcKey: 'mono',
    domain: _monoNotifier,
    applyOverride: () => _monoOverride = enabled,
    send: () => engine.action.setMono(monoDownmix),
    onSettled: () {
      if (_monoOverride != null && engine.state.mono == _monoOverride) {
        _monoOverride = null;
      }
    },
  );

  Future<void> setLimiterEnabled(bool enabled) => _setOptimisticScalar(
    rpcKey: 'limiter',
    domain: _limiterNotifier,
    applyOverride: () => _limiterOverride = enabled,
    send: () => engine.action.setLimiter(limiterEnabled),
    onSettled: () {
      if (_limiterOverride != null &&
          engine.state.limiterEnabled == _limiterOverride) {
        _limiterOverride = null;
      }
    },
  );

  // --- Silence Skipping ---
  Future<void> _applySilenceConfig(SilenceSkipConfig target) =>
      _setOptimisticScalar(
        rpcKey: 'silence',
        domain: _silenceNotifier,
        applyOverride: () {
          if (target.mode != SilenceSkipMode.disabled) {
            _silenceMode = target.mode;
          }
          _silenceConfigOverride = target;
        },
        send: () =>
            engine.action.setSilenceConfig(_silenceConfigOverride ?? target),
        onSettled: () {
          if (_silenceConfigOverride != null &&
              _silenceConfigEquals(
                engine.state.silenceConfig,
                _silenceConfigOverride!,
              )) {
            _silenceConfigOverride = null;
          }
        },
      );

  Future<void> setSilenceSkipEnabled(bool enabled) => _applySilenceConfig(
    _effectiveSilenceConfig.copyWith(
      enabled: enabled,
      mode: enabled ? _silenceMode : SilenceSkipMode.disabled,
      thresholdDb: silenceThresholdDb,
    ),
  );

  Future<void> setSilenceMode(SilenceSkipMode mode) => _applySilenceConfig(
    _effectiveSilenceConfig.copyWith(
      enabled: mode != SilenceSkipMode.disabled,
      mode: mode,
      thresholdDb: silenceThresholdDb,
    ),
  );

  Future<void> setSilenceThresholdDb(double thresholdDb) => _applySilenceConfig(
    _effectiveSilenceConfig.copyWith(
      enabled: silenceEnabled,
      mode: silenceEnabled ? _silenceMode : SilenceSkipMode.disabled,
      thresholdDb: thresholdDb,
    ),
  );

  Future<void> setMinSilenceDurationMs(int durationMs) => _applySilenceConfig(
    _effectiveSilenceConfig.copyWith(
      minSilenceDuration: Duration(milliseconds: durationMs),
    ),
  );

  Future<void> setSilencePaddingMs(int paddingMs) => _applySilenceConfig(
    _effectiveSilenceConfig.copyWith(
      padding: Duration(milliseconds: paddingMs),
    ),
  );

  // --- Visualizer & Metadata Event Stream Switches ---
  Future<void> setVisualizerEnabled(bool enabled) {
    MapLogger.debug(
      '[VISUALIZER:STATE] Real-time 10-band FFT visualizer: ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _setOptimisticScalar(
      rpcKey: 'visualizerEnabled',
      domain: _visualizerControlsNotifier,
      applyOverride: () => _visualizerEnabledOverride = enabled,
      send: () => engine.action.setVisualizerEnabled(visualizerEnabled),
      onSettled: () {
        if (_visualizerEnabledOverride != null &&
            engine.state.visualizerEnabled == _visualizerEnabledOverride) {
          _visualizerEnabledOverride = null;
        }
      },
    );
  }

  Future<void> setVisualizerSource(AudioOutputSource source) {
    MapLogger.info(
      '[VISUALIZER:SOURCE] Routing FFT audio analysis feed to: ${source.name.toUpperCase()}',
    );
    return _setOptimisticScalar(
      rpcKey: 'visualizerSource',
      domain: _visualizerControlsNotifier,
      applyOverride: () => _visualizerSourceOverride = source,
      send: () => engine.action.setVisualizerSource(visualizerSource),
      onSettled: () {
        if (_visualizerSourceOverride != null &&
            engine.state.visualizerSource == _visualizerSourceOverride) {
          _visualizerSourceOverride = null;
        }
      },
    );
  }

  Future<void> setMetadataEnabled(bool enabled) {
    MapLogger.info(
      '[METADATA:STREAM] Real-time live stream metadata parser: ${enabled ? "ENABLED" : "SUSPENDED"}',
    );
    return _setOptimisticScalar(
      rpcKey: 'metadataEnabled',
      domain: _metadataEnabledNotifier,
      applyOverride: () => _metadataEnabledOverride = enabled,
      send: () => engine.action.setMetadataEnabled(metadataEnabled),
      onSettled: () {
        if (_metadataEnabledOverride != null &&
            engine.state.metadataEnabled == _metadataEnabledOverride) {
          _metadataEnabledOverride = null;
        }
      },
    );
  }

  // --- Native RAM Sound Effects (Voices & Memory HUD) ---
  Future<void> loadSampleEffects() async {
    if (_isDisposed) return;
    final beepBytes = MockData.generateSineWaveBytes(
      frequency: 440,
      durationSeconds: 0.25,
    );
    final laserBytes = MockData.generateSineWaveBytes(
      frequency: 880,
      durationSeconds: 0.20,
    );
    final chimeBytes = MockData.generateSineWaveBytes(
      frequency: 1320,
      durationSeconds: 0.35,
    );

    if (_isDisposed) return;
    try {
      await engine.action.setEffects([
        AudioEffect(
          id: 'sfx_beep',
          source: AudioSource(beepBytes),
          maxPolyphony: 8,
        ),
        AudioEffect(
          id: 'sfx_laser',
          source: AudioSource(laserBytes),
          maxPolyphony: 8,
        ),
        AudioEffect(
          id: 'sfx_chime',
          source: AudioSource(chimeBytes),
          maxPolyphony: 8,
        ),
      ]);
      _notifyDomain();
    } catch (e) {
      if (!_isDisposed) {
        debugPrint('Failed to load sample sound effects: $e');
      }
    }
  }

  Future<Voice?> playSampleEffect(
    String id, {
    double volume = 1.0,
    double pitch = 1.0,
  }) async {
    return await engine.action.playEffect(
      id,
      config: EffectConfig(volume: volume, pitch: pitch),
    );
  }

  Future<void> unloadAllEffects() async {
    await engine.action.setEffects([]);
    _notifyDomain();
  }

  // --- Monotonic ID Queue Operations ---
  Future<void> reorderQueueByIds(List<int> ids) async {
    await engine.action.reorderByIds(ids);
    _notifyDomain(_queueNotifier);
  }

  Future<void> reverseQueueByIds() async {
    final ids = engine.state.queue
        .where((s) => s.id != null)
        .map((s) => s.id!)
        .toList()
        .reversed
        .toList();
    if (ids.isNotEmpty) {
      await engine.action.reorderByIds(ids);
      _notifyDomain(_queueNotifier);
    }
  }

  // --- Transport ---
  Future<void> setVolume(double val) => _setOptimisticScalar(
    rpcKey: 'volume',
    domain: _transportControlsNotifier,
    applyOverride: () => _volumeOverride = val,
    send: () => engine.action.setVolume(volume),
    onSettled: () {
      if (_volumeOverride != null && engine.state.volume == _volumeOverride) {
        _volumeOverride = null;
      }
    },
  );

  Future<void> setRate(double val) => _setOptimisticScalar(
    rpcKey: 'rate',
    domain: _transportControlsNotifier,
    applyOverride: () => _rateOverride = val,
    send: () => engine.action.setRate(rate),
    onSettled: () {
      if (_rateOverride != null && engine.state.rate == _rateOverride) {
        _rateOverride = null;
      }
    },
  );

  Future<void> setPitch(double val) => _setOptimisticScalar(
    rpcKey: 'pitch',
    domain: _transportControlsNotifier,
    applyOverride: () => _pitchOverride = val,
    send: () => engine.action.setPitch(pitch),
    onSettled: () {
      if (_pitchOverride != null && engine.state.pitch == _pitchOverride) {
        _pitchOverride = null;
      }
    },
  );

  Future<void> setPauseOnDeviceChange(bool enabled) => _setOptimisticScalar(
    rpcKey: 'pauseOnDeviceChange',
    domain: _pauseOnDeviceChangeNotifier,
    applyOverride: () => _pauseOnDeviceChangeOverride = enabled,
    send: () => engine.action.setPauseOnDeviceChange(pauseOnDeviceChange),
    onSettled: () {
      if (_pauseOnDeviceChangeOverride != null &&
          engine.state.pauseOnDeviceChange == _pauseOnDeviceChangeOverride) {
        _pauseOnDeviceChangeOverride = null;
      }
    },
  );

  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _pendingRpcs.clear();
    _inFlightRpcs.clear();
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    for (final notifier in _domainNotifiers) {
      notifier.dispose();
    }
    engine.dispose();
    super.dispose();
  }
}
