import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../models/audio_track.dart';
import '../models/mock_data.dart';

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
          notifyListeners();
        }
      }
    }
  }

  void resetWaveformToSinusoidal() {
    if (_waveformPoints != null) {
      _waveformPoints = null;
      notifyListeners();
    }
  }

  /// Checks whether waveform points have been cached in the engine for [trackId].
  bool hasCachedWaveform(String trackId) => _waveformCache.containsKey(trackId);

  /// Retrieves the cached waveform points for [trackId], or null if unanalyzed.
  List<double>? getCachedWaveform(String trackId) => _waveformCache[trackId];

  double? _preampOverride;
  double get preampDb => _preampOverride ?? engine.state.preamp;

  Future<void> setPreamp(double db) async {
    _preampOverride = db;
    notifyListeners();
    await engine.action.setPreamp(db);
  }

  bool get replayGainEnabled => engine.state.volumeNormalization;
  ReplayGainMode? _replayGainModeOverride;
  ReplayGainMode get replayGainMode =>
      _replayGainModeOverride ?? engine.state.replayGainMode;
  double get defaultReplayGain => engine.state.defaultReplayGain;

  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    _replayGainModeOverride = mode;
    notifyListeners();
    MapLogger.info(
      '[REPLAY_GAIN:MODE] Operating mode changed to: ${mode.name.toUpperCase()}',
    );
    await engine.action.setReplayGainMode(mode);
  }

  Future<void> setDefaultReplayGain(double gainDb) async {
    MapLogger.info(
      '[REPLAY_GAIN:DEFAULT] Fallback target gain set to: $gainDb dB',
    );
    await engine.action.setDefaultReplayGain(gainDb);
    notifyListeners();
  }

  String _selectedPreset = 'flat';
  Equalizer? _equalizerOverride;
  int _pendingEqualizerUpdates = 0;
  String _selectedReverbPreset = 'Studio';
  Reverb? _reverbOverride;
  int _pendingReverbUpdates = 0;
  Reverb _lastActiveReverb = Reverb.studio;

  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool get isReady => _isReady;
  bool get isLoadingTrack => _isLoadingTrack;

  AudioTrack? _currentTrack;

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

  CrossfadeConfig get crossfadeConfig => engine.state.crossfadeConfig;
  bool get isShuffle => engine.state.isShuffled;
  bool get isLoop => engine.state.loopMode != LoopMode.off;
  LoopMode get loopMode => engine.state.loopMode;

  Equalizer get currentEqualizer => _equalizerOverride ?? engine.state.equalizer;
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
  int _pendingCrossfeedUpdates = 0;
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
  bool? _silenceEnabledOverride;
  double? _silenceThresholdDbOverride;
  int _pendingSilenceThresholdUpdates = 0;

  bool get silenceEnabled =>
      _silenceEnabledOverride ??
      (engine.state.silenceConfig.mode != SilenceSkipMode.disabled);
  SilenceSkipMode get silenceMode =>
      engine.state.silenceConfig.mode != SilenceSkipMode.disabled
      ? engine.state.silenceConfig.mode
      : _silenceMode;
  double get silenceThresholdDb =>
      _silenceThresholdDbOverride ?? engine.state.silenceConfig.thresholdDb;
  int get minSilenceDurationMs =>
      engine.state.silenceConfig.minSilenceDuration.inMilliseconds;
  int get silencePaddingMs => engine.state.silenceConfig.padding.inMilliseconds;
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
  int get selectedBufferSize => engine.state.bufferSize;

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
    _recordingFormat = fmt;
    notifyListeners();
  }

  void setRecordingSource(AudioOutputSource src) {
    _recordingSource = src;
    notifyListeners();
  }

  Future<void> startRecording({String? customPath}) async {
    final String tempDir = !kIsWeb ? Directory.systemTemp.path : '/tmp';
    final String path =
        customPath ??
        '$tempDir/studio_recording_${DateTime.now().millisecondsSinceEpoch}.${_recordingFormat.name}';
    await engine.action.startRecording(
      path,
      format: _recordingFormat,
      source: _recordingSource,
    );
    notifyListeners();
  }

  Future<RecordingResult> stopRecording() async {
    final res = await engine.action.stopRecording();
    _lastRecordingResult = res;
    notifyListeners();
    return res;
  }

  Future<void> init() async {
    _cachedTracks = await MockData.loadTracks();

    _bindSubscriptions();

    _isReady = true;
    notifyListeners();

    if (_cachedTracks.isNotEmpty) {
      final items = _cachedTracks
          .map((t) => t.source.withData<AudioTrack>(t))
          .toList();
      try {
        await engine.action.setQueue(items);
      } catch (_) {}
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

    // Load sample effects in the background so the console can mount immediately
    unawaited(loadSampleEffects());
    notifyListeners();
  }

  void _bindSubscriptions() {
    _subscriptions.add(
      engine.stream.currentItem.listen((item) {
        if (item?.data != null && item!.data is AudioTrack) {
          final track = item.data as AudioTrack;
          _currentTrack = track;
          if (_waveformCache.containsKey(track.id)) {
            _waveformPoints = _waveformCache[track.id];
          } else {
            _waveformPoints = null;
          }
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.currentIndex.listen((_) => notifyListeners()),
    );
    _subscriptions.add(engine.stream.queue.listen((_) => notifyListeners()));
    _subscriptions.add(
      engine.stream.isShuffled.listen((_) => notifyListeners()),
    );
    _subscriptions.add(engine.stream.loopMode.listen((_) => notifyListeners()));
    _subscriptions.add(
      engine.stream.crossfadeConfig.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.playbackState.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.spatializerWidth.listen((_) {
        _spatializerWidthOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.spatializerEnabled.listen((_) {
        _spatializerEnabledOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.visualizerEnabled.listen((_) {
        _visualizerEnabledOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.visualizerSource.listen((_) {
        _visualizerSourceOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.metadataEnabled.listen((_) {
        _metadataEnabledOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.pauseOnDeviceChange.listen((_) {
        _pauseOnDeviceChangeOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.silenceConfig.listen((_) {
        _silenceEnabledOverride = null;
        if (_pendingSilenceThresholdUpdates == 0) {
          _silenceThresholdDbOverride = null;
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.mono.listen((_) {
        _monoOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.limiterEnabled.listen((_) {
        _limiterOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(engine.stream.metadata.listen((_) => notifyListeners()));
    _subscriptions.add(
      engine.stream.volume.listen((_) {
        _volumeOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.rate.listen((_) {
        _rateOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.pitch.listen((_) {
        _pitchOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.equalizer.listen((eq) {
        if (_pendingEqualizerUpdates > 0) return;
        _equalizerOverride = null;
        _selectedPreset = _detectPreset(eq) ?? 'custom';
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.reverb.listen((rev) {
        if (_pendingReverbUpdates > 0) return;
        _reverbOverride = null;
        if (rev != Reverb.off) {
          _lastActiveReverb = rev.copyWith(enabled: true);
        }
        _selectedReverbPreset =
            _detectReverbPreset(_lastActiveReverb) ?? 'Custom';
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.preamp.listen((_) {
        _preampOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.replayGain.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.replayGainMode.listen((_) {
        _replayGainModeOverride = null;
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.crossfeed.listen((_) {
        if (_pendingCrossfeedUpdates == 0) {
          _crossfeedOverride = null;
        }
        notifyListeners();
      }),
    );
    _subscriptions.add(
      engine.stream.silenceConfig.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.silenceSavedDuration.listen((_) => notifyListeners()),
    );
    _subscriptions.add(engine.stream.outputs.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.inputs.listen((_) => notifyListeners()));
    _subscriptions.add(
      engine.stream.isRecording.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.isDuckingActive.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.pauseOnDeviceChange.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.globalOutputDevices.listen((_) => notifyListeners()),
    );
    _subscriptions.add(
      engine.stream.globalInputDevices.listen((_) => notifyListeners()),
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
    notifyListeners();
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
    notifyListeners();
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
    notifyListeners();
  }

  Future<void> configureInputDevice(
    String deviceId,
    AudioInputConfig config,
  ) async {
    _inputConfigs[deviceId] = config;
    if (engine.state.inputs.any((i) => i.deviceId == deviceId)) {
      await engine.action.configureInput(config, deviceId: deviceId);
    }
    notifyListeners();
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

  Future<void> _applyEqualizer(Equalizer target) async {
    _pendingEqualizerUpdates++;
    _equalizerOverride = target;
    _selectedPreset = _detectPreset(target) ?? 'custom';
    notifyListeners();
    try {
      await engine.action.setEqualizer(target);
    } finally {
      _pendingEqualizerUpdates--;
      if (_pendingEqualizerUpdates == 0 && engine.state.equalizer == target) {
        _equalizerOverride = null;
        notifyListeners();
      }
    }
  }

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

  Future<void> _applyReverb(Reverb target) async {
    _pendingReverbUpdates++;
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
    notifyListeners();
    try {
      await engine.action.setReverb(target);
    } finally {
      _pendingReverbUpdates--;
      if (_pendingReverbUpdates == 0 && engine.state.reverb == target) {
        _reverbOverride = null;
        notifyListeners();
      }
    }
  }

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
    _isLoadingTrack = true;
    _currentTrack = track;
    if (_waveformCache.containsKey(track.id)) {
      _waveformPoints = _waveformCache[track.id];
    } else {
      _waveformPoints = null;
    }
    notifyListeners();

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
        notifyListeners();
      }
    }
  }

  Future<void> addTrack(AudioTrack track) async {
    _cachedTracks = [..._cachedTracks, track];
    final item = track.source.withData<AudioTrack>(track);
    await engine.action.append([item]);
    await engine.action.play(position: engine.state.queue.length - 1);
    notifyListeners();
  }

  Future<void> reorderTrack(int oldIndex, int newIndex) async {
    await engine.action.reorder(oldIndex, newIndex);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    await engine.action.setShuffle(!engine.state.isShuffled);
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    final nextMode = engine.state.loopMode == LoopMode.off
        ? LoopMode.all
        : engine.state.loopMode == LoopMode.all
        ? LoopMode.one
        : LoopMode.off;
    await engine.action.setLoopMode(nextMode);
    notifyListeners();
  }

  Future<void> nextTrack() async {
    _currentTrack = null;
    resetWaveformToSinusoidal();
    await engine.action.next();
    notifyListeners();
  }

  Future<void> previousTrack() async {
    _currentTrack = null;
    resetWaveformToSinusoidal();
    await engine.action.previous();
    notifyListeners();
  }

  // --- Crossfade Configuration ---
  Future<void> setCrossfadeCurve(CrossfadeCurve curve) async {
    await engine.action.setCrossfade(
      engine.state.crossfadeConfig.copyWith(curve: curve),
    );
    notifyListeners();
  }

  Future<void> setCrossfadeDuration(Duration duration) async {
    await engine.action.setCrossfade(
      engine.state.crossfadeConfig.copyWith(autoDuration: duration),
    );
    notifyListeners();
  }

  Future<void> setManualCrossfadeDuration(Duration duration) async {
    await engine.action.setCrossfade(
      engine.state.crossfadeConfig.copyWith(manualDuration: duration),
    );
    notifyListeners();
  }

  // --- Crossfeed Controls ---
  Future<void> setCrossfeed(Crossfeed cf) async {
    _pendingCrossfeedUpdates++;
    _crossfeedOverride = cf;
    notifyListeners();
    try {
      await engine.action.setCrossfeed(cf);
    } finally {
      _pendingCrossfeedUpdates--;
      if (_pendingCrossfeedUpdates == 0 && engine.state.crossfeed == cf) {
        _crossfeedOverride = null;
        notifyListeners();
      }
    }
  }

  Future<void> toggleCrossfeed(bool enabled) async {
    await setCrossfeed(crossfeed.copyWith(enabled: enabled));
  }

  Future<void> setCrossfeedCutoff(double cutoffHz) async {
    await setCrossfeed(crossfeed.copyWith(cutoffHz: cutoffHz));
  }

  Future<void> setCrossfeedFeed(double feedDb) async {
    await setCrossfeed(crossfeed.copyWith(feedDb: feedDb));
  }

  // --- Spatializer, Balance, Mono, Limiter ---
  Future<void> setSpatializerEnabled(bool enabled) async {
    _spatializerEnabledOverride = enabled;
    notifyListeners();
    await engine.action.setSpatializer(
      enabled: enabled,
      width: spatializerWidth,
    );
  }

  Future<void> setSpatializerWidth(double width) async {
    _spatializerWidthOverride = width;
    notifyListeners();
    await engine.action.setSpatializer(
      enabled: spatializerEnabled,
      width: width,
    );
  }

  Future<void> setStereoBalance(double balance) async {
    _stereoBalanceOverride = balance;
    notifyListeners();
    await engine.action.setBalance(balance);
  }

  Future<void> setMonoDownmix(bool enabled) async {
    _monoOverride = enabled;
    notifyListeners();
    await engine.action.setMono(enabled);
  }

  Future<void> setLimiterEnabled(bool enabled) async {
    _limiterOverride = enabled;
    notifyListeners();
    await engine.action.setLimiter(enabled);
  }

  // --- Silence Skipping ---
  Future<void> setSilenceSkipEnabled(bool enabled) async {
    _silenceEnabledOverride = enabled;
    notifyListeners();
    final modeToApply = enabled ? _silenceMode : SilenceSkipMode.disabled;
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(
        enabled: enabled,
        mode: modeToApply,
        thresholdDb: silenceThresholdDb,
      ),
    );
  }

  Future<void> setSilenceMode(SilenceSkipMode mode) async {
    _silenceMode = mode;
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(
        enabled: mode != SilenceSkipMode.disabled,
        mode: mode,
        thresholdDb: silenceThresholdDb,
      ),
    );
    notifyListeners();
  }

  Future<void> setSilenceThresholdDb(double thresholdDb) async {
    _pendingSilenceThresholdUpdates++;
    _silenceThresholdDbOverride = thresholdDb;
    notifyListeners();
    try {
      await engine.action.setSilenceConfig(
        engine.state.silenceConfig.copyWith(
          enabled: silenceEnabled,
          mode: silenceEnabled ? _silenceMode : SilenceSkipMode.disabled,
          thresholdDb: thresholdDb,
        ),
      );
    } finally {
      _pendingSilenceThresholdUpdates--;
      if (_pendingSilenceThresholdUpdates == 0 &&
          engine.state.silenceConfig.thresholdDb == thresholdDb) {
        _silenceThresholdDbOverride = null;
        notifyListeners();
      }
    }
  }

  Future<void> setMinSilenceDurationMs(int durationMs) async {
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(
        minSilenceDuration: Duration(milliseconds: durationMs),
      ),
    );
    notifyListeners();
  }

  Future<void> setSilencePaddingMs(int paddingMs) async {
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(
        padding: Duration(milliseconds: paddingMs),
      ),
    );
    notifyListeners();
  }

  // --- Visualizer & Metadata Event Stream Switches ---
  Future<void> setVisualizerEnabled(bool enabled) async {
    _visualizerEnabledOverride = enabled;
    notifyListeners();
    MapLogger.debug(
      '[VISUALIZER:STATE] Real-time 10-band FFT visualizer: ${enabled ? "ENABLED" : "DISABLED"}',
    );
    await engine.action.setVisualizerEnabled(enabled);
  }

  Future<void> setVisualizerSource(AudioOutputSource source) async {
    _visualizerSourceOverride = source;
    notifyListeners();
    MapLogger.info(
      '[VISUALIZER:SOURCE] Routing FFT audio analysis feed to: ${source.name.toUpperCase()}',
    );
    await engine.action.setVisualizerSource(source);
  }

  Future<void> setMetadataEnabled(bool enabled) async {
    _metadataEnabledOverride = enabled;
    notifyListeners();
    MapLogger.info(
      '[METADATA:STREAM] Real-time live stream metadata parser: ${enabled ? "ENABLED" : "SUSPENDED"}',
    );
    await engine.action.setMetadataEnabled(enabled);
  }

  // --- Native RAM Sound Effects (Voices & Memory HUD) ---
  Future<void> loadSampleEffects() async {
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
      notifyListeners();
    } catch (e) {
      debugPrint('Failed to load sample sound effects: $e');
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
    notifyListeners();
  }

  // --- Monotonic ID Queue Operations ---
  Future<void> reorderQueueByIds(List<int> ids) async {
    await engine.action.reorderByIds(ids);
    notifyListeners();
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
      notifyListeners();
    }
  }

  // --- Transport ---
  Future<void> setVolume(double val) async {
    _volumeOverride = val;
    notifyListeners();
    await engine.action.setVolume(val);
  }

  Future<void> setRate(double val) async {
    _rateOverride = val;
    notifyListeners();
    await engine.action.setRate(val);
  }

  Future<void> setPitch(double val) async {
    _pitchOverride = val;
    notifyListeners();
    await engine.action.setPitch(val);
  }

  Future<void> setBufferSize(int size) async {
    await engine.action.setBufferSize(size);
    notifyListeners();
  }

  Future<void> setPauseOnDeviceChange(bool enabled) async {
    _pauseOnDeviceChangeOverride = enabled;
    notifyListeners();
    await engine.action.setPauseOnDeviceChange(enabled);
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    engine.dispose();
    super.dispose();
  }
}
