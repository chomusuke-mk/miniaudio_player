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
    crossfadeConfig: CrossfadeConfig(
      autoDuration: const Duration(seconds: 5),
      manualDuration: const Duration(milliseconds: 100),
      curve: CrossfadeCurve.equalPower,
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
        _waveformPoints = unmod;
        notifyListeners();
      }
    }
  }

  void resetWaveformToSinusoidal() {
    _waveformPoints = null;
    notifyListeners();
  }

  double? _preampOverride;
  double get preampDb => _preampOverride ?? engine.state.preamp;

  Future<void> setPreamp(double db) async {
    _preampOverride = db;
    notifyListeners();
    await engine.action.setPreamp(db);
  }

  bool get replayGainEnabled => engine.state.volumeNormalization;
  ReplayGainMode get replayGainMode => engine.state.replayGainMode;
  double get defaultReplayGain => engine.state.defaultReplayGain;

  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    MapLogger.info(
      '[REPLAY_GAIN:MODE] Operating mode changed to: ${mode.name.toUpperCase()}',
    );
    await engine.action.setReplayGainMode(mode);
    notifyListeners();
  }

  Future<void> setDefaultReplayGain(double gainDb) async {
    MapLogger.info(
      '[REPLAY_GAIN:DEFAULT] Fallback target gain set to: $gainDb dB',
    );
    await engine.action.setDefaultReplayGain(gainDb);
    notifyListeners();
  }

  String _selectedPreset = 'flat';
  String _selectedReverbPreset = 'Off';

  List<AudioDevice> _audioDevices = [AudioDevice.auto];
  List<AudioDevice> _inputDevices = [];
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  bool get isReady => _isReady;
  bool get isLoadingTrack => _isLoadingTrack;

  AudioTrack? _currentTrack;

  AudioTrack? get selectedTrack {
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

  Equalizer get currentEqualizer => engine.state.equalizer;
  String get selectedPreset => _selectedPreset;

  Reverb get currentReverb => engine.state.reverb;
  String get selectedReverbPreset => _selectedReverbPreset;
  double get reverbRoomSize => engine.state.reverb.roomSize;
  double get reverbDamping => engine.state.reverb.damping;
  double get reverbWidth => engine.state.reverb.width;
  double get reverbWet => engine.state.reverb.wet;
  double get reverbDry => engine.state.reverb.dry;
  double get reverbWetDry => engine.state.reverb.wet;
  bool get reverbEnabled => engine.state.reverb.enabled;

  Crossfeed get crossfeed => engine.state.crossfeed;
  double? _spatializerWidthOverride;
  double get spatializerWidth => _spatializerWidthOverride ?? engine.state.spatializerWidth;
  bool get spatializerEnabled => engine.state.spatializerEnabled;

  double? _stereoBalanceOverride;
  double get stereoBalance => _stereoBalanceOverride ?? engine.state.balance;

  bool? _monoOverride;
  bool get monoDownmix => _monoOverride ?? engine.state.mono;

  bool? _limiterOverride;
  bool get limiterEnabled => _limiterOverride ?? engine.state.limiterEnabled;

  SilenceSkipMode _silenceMode = SilenceSkipMode.all;
  bool? _silenceEnabledOverride;

  bool get silenceEnabled =>
      _silenceEnabledOverride ??
      (engine.state.silenceConfig.mode != SilenceSkipMode.disabled);
  SilenceSkipMode get silenceMode =>
      engine.state.silenceConfig.mode != SilenceSkipMode.disabled
          ? engine.state.silenceConfig.mode
          : _silenceMode;
  double get silenceThresholdDb => engine.state.silenceConfig.thresholdDb;
  int get minSilenceDurationMs =>
      engine.state.silenceConfig.minSilenceDuration.inMilliseconds;
  int get silencePaddingMs =>
      engine.state.silenceConfig.padding.inMilliseconds;
  Duration get silenceSavedDuration => engine.state.silenceSavedDuration;

  bool? _visualizerEnabledOverride;
  bool get visualizerEnabled =>
      _visualizerEnabledOverride ?? engine.state.visualizerEnabled;

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
  List<AudioDevice> get audioDevices => _audioDevices;
  List<AudioDevice> get inputDevices => _inputDevices;
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
    final String path = customPath ??
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

    try {
      final outDevs = engine.state.globalOutputDevices;
      if (outDevs.isNotEmpty) _audioDevices = outDevs;
      final inDevs = engine.state.globalInputDevices;
      if (inDevs.isNotEmpty) _inputDevices = inDevs;
    } catch (_) {}

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
    _subscriptions.add(engine.stream.currentItem.listen((item) {
      if (item?.data != null) {
        _currentTrack = item!.data;
      }
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.currentIndex.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.queue.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.isShuffled.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.loopMode.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.crossfadeConfig.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.playbackState.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.spatializerWidth.listen((_) {
      _spatializerWidthOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.spatializerEnabled.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.visualizerEnabled.listen((_) {
      _visualizerEnabledOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.metadataEnabled.listen((_) {
      _metadataEnabledOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.pauseOnDeviceChange.listen((_) {
      _pauseOnDeviceChangeOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.silenceConfig.listen((_) {
      _silenceEnabledOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.mono.listen((_) {
      _monoOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.limiterEnabled.listen((_) {
      _limiterOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.metadata.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.buffer.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.allocatedRamBytes.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.loadedEffectIds.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.activeVoicesCount.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.volume.listen((_) {
      _volumeOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.rate.listen((_) {
      _rateOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.pitch.listen((_) {
      _pitchOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.equalizer.listen((eq) {
      _selectedPreset = _detectPreset(eq) ?? 'custom';
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.reverb.listen((rev) {
      _selectedReverbPreset = _detectReverbPreset(rev) ?? 'Custom';
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.preamp.listen((_) {
      _preampOverride = null;
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.replayGain.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.replayGainMode.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.crossfeed.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.limiterEnabled.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.silenceConfig.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.silenceSavedDuration.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.outputs.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.inputs.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.isRecording.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.recordedDuration.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.isDuckingActive.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.micRmsLevel.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.pauseOnDeviceChange.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.globalOutputDevices.listen((list) {
      if (list.isNotEmpty) {
        _audioDevices = list;
        notifyListeners();
      }
    }));
    _subscriptions.add(engine.stream.globalInputDevices.listen((list) {
      if (list.isNotEmpty) {
        _inputDevices = list;
        notifyListeners();
      }
    }));
  }

  // --- Multi-Destination Output Management ---
  Future<void> toggleOutput(AudioDevice device, {AudioOutputSource source = AudioOutputSource.all}) async {
    final curOutputs = Set<AudioOutput>.of(engine.state.outputs);
    final exists = curOutputs.any((o) => o.deviceId == device.id);
    if (exists) {
      curOutputs.removeWhere((o) => o.deviceId == device.id);
      if (curOutputs.isEmpty) {
        curOutputs.add(const AudioOutput());
      }
    } else {
      curOutputs.add(AudioOutput(deviceId: device.id, source: source));
    }
    await engine.action.setOutputs(curOutputs);
    notifyListeners();
  }

  Future<void> setOutputSource(String deviceId, AudioOutputSource source) async {
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

  Future<void> configureInputDevice(String deviceId, AudioInputConfig config) async {
    _inputConfigs[deviceId] = config;
    if (engine.state.inputs.any((i) => i.deviceId == deviceId)) {
      await engine.action.configureInput(config, deviceId: deviceId);
    }
    notifyListeners();
  }

  // --- Equalizer ---
  static String? _detectPreset(Equalizer eq) {
    if (eq == Equalizer.flat) return 'flat';
    if (eq == Equalizer.rock) return 'rock';
    if (eq == Equalizer.pop) return 'pop';
    if (eq == Equalizer.jazz) return 'jazz';
    if (eq == Equalizer.classical) return 'classical';
    if (eq == Equalizer.bassBoost) return 'bassBoost';
    return null;
  }

  Future<void> setEqualizerPreset(String presetKey) async {
    _selectedPreset = presetKey;
    Equalizer eq;
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
    await engine.action.setEqualizer(eq);
    notifyListeners();
  }

  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    final list = engine.state.equalizer.toList();
    if (bandIndex >= 0 && bandIndex < list.length) {
      list[bandIndex] = gainDb;
      await engine.action.setEqualizer(Equalizer.fromList(list));
      _selectedPreset = _detectPreset(engine.state.equalizer) ?? 'custom';
      notifyListeners();
    }
  }

  // --- Reverb ---
  static String? _detectReverbPreset(Reverb rev) {
    for (final entry in Reverb.presets.entries) {
      if (entry.value == rev) return entry.key;
    }
    return null;
  }

  Future<void> setReverbPreset(String name) async {
    _selectedReverbPreset = name;
    final preset = Reverb.presets[name] ?? Reverb.off;
    await engine.action.setReverb(preset);
    notifyListeners();
  }

  Future<void> setReverbParams({
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
    bool? enabled,
  }) async {
    final current = engine.state.reverb;
    await engine.action.setReverb(
      current.copyWith(
        enabled: enabled ?? true,
        roomSize: roomSize,
        damping: damping,
        width: width,
        wet: wet,
        dry: dry,
      ),
    );
    _selectedReverbPreset = _detectReverbPreset(engine.state.reverb) ?? 'Custom';
    notifyListeners();
  }

  // --- Track Selection & Queue Navigation ---
  Future<void> selectTrack(AudioTrack track, {bool autoPlay = false}) async {
    if (_isLoadingTrack) return;
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
      if (idx != -1) {
        await engine.action.play(position: idx);
      } else {
        final item = track.source.withData<AudioTrack>(track);
        await engine.action.insertNext(item);
        await engine.action.next();
      }
      if (autoPlay) {
        await engine.action.play();
      }
    } catch (e) {
      debugPrint('Error selecting track in engine: $e');
    } finally {
      _isLoadingTrack = false;
      notifyListeners();
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
    await engine.action.setCrossfeed(cf);
    notifyListeners();
  }

  Future<void> toggleCrossfeed(bool enabled) async {
    await setCrossfeed(engine.state.crossfeed.copyWith(enabled: enabled));
  }

  Future<void> setCrossfeedCutoff(double cutoffHz) async {
    await setCrossfeed(engine.state.crossfeed.copyWith(cutoffHz: cutoffHz));
  }

  Future<void> setCrossfeedFeed(double feedDb) async {
    await setCrossfeed(engine.state.crossfeed.copyWith(feedDb: feedDb));
  }

  // --- Spatializer, Balance, Mono, Limiter ---
  Future<void> setSpatializerEnabled(bool enabled) async {
    await engine.action.setSpatializer(
      enabled: enabled,
      width: spatializerWidth,
    );
    notifyListeners();
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
      ),
    );
  }

  Future<void> setSilenceMode(SilenceSkipMode mode) async {
    _silenceMode = mode;
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(
        enabled: mode != SilenceSkipMode.disabled,
        mode: mode,
      ),
    );
    notifyListeners();
  }

  Future<void> setSilenceThresholdDb(double thresholdDb) async {
    await engine.action.setSilenceConfig(
      engine.state.silenceConfig.copyWith(thresholdDb: thresholdDb),
    );
    notifyListeners();
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
    final beepBytes = MockData.generateSineWaveBytes(frequency: 440, durationSeconds: 0.25);
    final laserBytes = MockData.generateSineWaveBytes(frequency: 880, durationSeconds: 0.20);
    final chimeBytes = MockData.generateSineWaveBytes(frequency: 1320, durationSeconds: 0.35);

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
    return await engine.action.playEffect(id, volume: volume, pitch: pitch);
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
