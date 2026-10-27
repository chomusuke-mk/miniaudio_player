import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../models/audio_track.dart';
import '../models/mock_data.dart';

/// Studio Master Console Engine Controller powered directly by [MiniaudioEngine].
///
/// Manages dual-deck audio threads, automated crossfades, reorderable playlist queue,
/// DSP effects (Equalizer, Reverb, Limiter, Silence Skipping, Crossfeed), and hardware routing.
class AudioEngineController extends ChangeNotifier {
  final MiniaudioEngine<AudioTrack> engine = MiniaudioEngine<AudioTrack>(
    crossfadeConfig: CrossfadeConfig(
      duration: const Duration(seconds: 5),
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

  double get preampDb => engine.state.preamp;

  Future<void> setPreamp(double db) async {
    await engine.action.setPreamp(db);
    notifyListeners();
  }

  bool get replayGainEnabled => engine.state.volumeNormalization;
  ReplayGainMode get replayGainMode => engine.state.replayGainMode;
  double get defaultReplayGain => engine.state.defaultReplayGain;
  double? get forcedReplayGain => engine.state.forcedReplayGain;

  Future<void> setReplayGainEnabled(bool enabled) async {
    await engine.action.setVolumeNormalization(enabled);
    notifyListeners();
  }

  Future<void> setDefaultReplayGain(double gainDb) async {
    await engine.action.setDefaultReplayGain(gainDb);
    notifyListeners();
  }

  Future<void> setForcedReplayGain(double? gainDb) async {
    await engine.action.setForcedReplayGain(gainDb);
    notifyListeners();
  }

  String _selectedPreset = 'flat';
  String _selectedReverbPreset = 'Off';

  List<AudioDevice> _audioDevices = [AudioDevice.auto];
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
      return queue.map((i) => i.data!).toList();
    }
    return _cachedTracks;
  }

  CrossfadeConfig get crossfadeConfig => engine.state.crossfadeConfig;
  bool get isShuffle => engine.state.shuffle;
  bool get isLoop => engine.state.loopMode != LoopMode.off;

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

  CrossfeedMode get crossfeedMode => engine.state.crossfeed;
  double get spatializerWidth => 1.3;
  double get stereoBalance => engine.state.balance;
  bool get monoDownmix => engine.state.mono;
  bool get limiterEnabled => engine.state.limiterEnabled;

  SilenceSkipMode _silenceMode = SilenceSkipMode.all;

  bool get silenceEnabled =>
      engine.state.silenceConfig.mode != SilenceSkipMode.disabled;
  SilenceSkipMode get silenceMode =>
      engine.state.silenceConfig.mode != SilenceSkipMode.disabled
          ? engine.state.silenceConfig.mode
          : _silenceMode;
  double get silenceThresholdDb => engine.state.silenceConfig.thresholdDb;
  int get minSilenceDurationMs =>
      engine.state.silenceConfig.minSilenceDuration.inMilliseconds;
  int get silencePaddingMs =>
      engine.state.silenceConfig.padding.inMilliseconds;

  bool get visualizerEnabled => engine.state.visualizerEnabled;

  double get volume => engine.state.volume;
  double get rate => engine.state.rate;
  double get pitch => engine.state.pitch;
  int get selectedBufferSize => engine.state.bufferSize;
  List<AudioDevice> get audioDevices => _audioDevices;
  AudioDevice get selectedDevice => engine.state.audioDevice;
  bool get pauseOnDeviceChange => engine.state.pauseOnDeviceChange;

  Future<void> init() async {
    _cachedTracks = await MockData.loadTracks();

    try {
      final devs = await MiniaudioPlayer.getAudioDevices();
      if (devs.isNotEmpty) _audioDevices = devs;
    } catch (_) {}

    if (_cachedTracks.isNotEmpty) {
      final items = _cachedTracks
          .map((t) => EngineItem<AudioTrack>(
                source: t.source,
                data: t,
                replayGainDb: t.replayGainDb,
                replayPeak: t.replayPeak,
              ))
          .toList();
      await engine.action.open(items, startIndex: 0);
    }

    await engine.action.setLimiter(true);
    await engine.action.setReverb(Reverb.off);
    await engine.action.setCrossfadeConfig(
      CrossfadeConfig(
        duration: const Duration(seconds: 5),
        manualDuration: const Duration(milliseconds: 100),
        curve: CrossfadeCurve.equalPower,
      ),
    );

    _bindSubscriptions();

    _isReady = true;
    notifyListeners();
  }

  void _bindSubscriptions() {
    _subscriptions.add(engine.stream.currentItem.listen((item) {
      if (item?.data != null) {
        _currentTrack = item!.data;
      }
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.queue.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.crossfadeConfig.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.playbackState.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.equalizer.listen((eq) {
      _selectedPreset = _detectPreset(eq) ?? 'custom';
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.reverb.listen((rev) {
      _selectedReverbPreset = _detectReverbPreset(rev) ?? 'Custom';
      notifyListeners();
    }));
    _subscriptions.add(engine.stream.preamp.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.volumeNormalization.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.replayGainMode.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.defaultReplayGain.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.forcedReplayGain.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.audioDevice.listen((_) => notifyListeners()));
    _subscriptions.add(engine.stream.pauseOnDeviceChange.listen((_) => notifyListeners()));
    _subscriptions.add(MiniaudioPlayer.getAudioDevicesStream().listen((list) {
      if (list.isNotEmpty) {
        _audioDevices = list;
        notifyListeners();
      }
    }));
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
    await engine.action.setEqualizerBand(bandIndex, gainDb);
    _selectedPreset = _detectPreset(engine.state.equalizer) ?? 'custom';
    notifyListeners();
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
        await engine.action.skipToIndex(idx);
      } else {
        final item = EngineItem<AudioTrack>(source: track.source, data: track);
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
    final item = EngineItem<AudioTrack>(source: track.source, data: track);
    await engine.action.append([item]);
    await engine.action.skipToIndex(engine.state.queue.length - 1);
    await engine.action.play();
    notifyListeners();
  }

  Future<void> reorderTrack(int oldIndex, int newIndex) async {
    await engine.action.reorder(oldIndex, newIndex);
    notifyListeners();
  }

  Future<void> toggleShuffle() async {
    await engine.action.setShuffle(!engine.state.shuffle);
    notifyListeners();
  }

  Future<void> toggleLoop() async {
    final nextMode = engine.state.loopMode == LoopMode.off
        ? LoopMode.all
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
    await engine.action.setCrossfadeCurve(curve);
    notifyListeners();
  }

  Future<void> setCrossfadeDuration(Duration duration) async {
    await engine.action.setCrossfadeDuration(duration);
    notifyListeners();
  }

  Future<void> setManualCrossfadeDuration(Duration duration) async {
    await engine.action.setManualCrossfadeDuration(duration);
    notifyListeners();
  }

  // --- Crossfeed, Spatializer, Balance, Limiter ---
  Future<void> setCrossfeedMode(CrossfeedMode mode) async {
    await engine.action.setCrossfeed(mode);
    notifyListeners();
  }

  Future<void> setSpatializerWidth(double width) async {
    await engine.action.setSpatializer(enabled: true, width: width);
    notifyListeners();
  }

  Future<void> setStereoBalance(double balance) async {
    await engine.action.setBalance(balance);
    notifyListeners();
  }

  Future<void> setMonoDownmix(bool enabled) async {
    await engine.action.setMono(enabled);
    notifyListeners();
  }

  Future<void> setLimiterEnabled(bool enabled) async {
    await engine.action.setLimiter(enabled);
    notifyListeners();
  }

  // --- Silence Skipping ---
  Future<void> setSilenceSkipEnabled(bool enabled) async {
    final modeToApply = enabled ? _silenceMode : SilenceSkipMode.disabled;
    await engine.action.setSkipSilence(
      enabled,
      mode: modeToApply,
      thresholdDb: engine.state.silenceConfig.thresholdDb,
      minSilenceDuration: engine.state.silenceConfig.minSilenceDuration,
      padding: engine.state.silenceConfig.padding,
    );
    notifyListeners();
  }

  Future<void> setSilenceMode(SilenceSkipMode mode) async {
    _silenceMode = mode;
    final enabled = engine.state.silenceConfig.mode != SilenceSkipMode.disabled;
    await engine.action.setSkipSilence(
      enabled,
      mode: mode,
      thresholdDb: engine.state.silenceConfig.thresholdDb,
      minSilenceDuration: engine.state.silenceConfig.minSilenceDuration,
      padding: engine.state.silenceConfig.padding,
    );
    notifyListeners();
  }

  Future<void> setSilenceThresholdDb(double thresholdDb) async {
    final enabled = engine.state.silenceConfig.mode != SilenceSkipMode.disabled;
    await engine.action.setSkipSilence(
      enabled,
      mode: engine.state.silenceConfig.mode,
      thresholdDb: thresholdDb,
      minSilenceDuration: engine.state.silenceConfig.minSilenceDuration,
      padding: engine.state.silenceConfig.padding,
    );
    notifyListeners();
  }

  Future<void> setMinSilenceDurationMs(int durationMs) async {
    final enabled = engine.state.silenceConfig.mode != SilenceSkipMode.disabled;
    await engine.action.setSkipSilence(
      enabled,
      mode: engine.state.silenceConfig.mode,
      thresholdDb: engine.state.silenceConfig.thresholdDb,
      minSilenceDuration: Duration(milliseconds: durationMs),
      padding: engine.state.silenceConfig.padding,
    );
    notifyListeners();
  }

  Future<void> setSilencePaddingMs(int paddingMs) async {
    final enabled = engine.state.silenceConfig.mode != SilenceSkipMode.disabled;
    await engine.action.setSkipSilence(
      enabled,
      mode: engine.state.silenceConfig.mode,
      thresholdDb: engine.state.silenceConfig.thresholdDb,
      minSilenceDuration: engine.state.silenceConfig.minSilenceDuration,
      padding: Duration(milliseconds: paddingMs),
    );
    notifyListeners();
  }

  // --- Visualizer ---
  Future<void> setVisualizerEnabled(bool enabled) async {
    await engine.action.setVisualizerEnabled(enabled);
    notifyListeners();
  }

  // --- Transport ---
  Future<void> setVolume(double val) async {
    await engine.action.setVolume(val);
    notifyListeners();
  }

  Future<void> setRate(double val) async {
    await engine.action.setRate(val);
    notifyListeners();
  }

  Future<void> setPitch(double val) async {
    await engine.action.setPitch(val);
    notifyListeners();
  }

  Future<void> setBufferSize(int size) async {
    await engine.action.setBufferSize(size);
    notifyListeners();
  }

  Future<void> setDevice(AudioDevice dev) async {
    await engine.action.setDevice(dev);
    notifyListeners();
  }

  Future<void> setPauseOnDeviceChange(bool enabled) async {
    engine.action.setPauseOnDeviceChange(enabled);
    notifyListeners();
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
