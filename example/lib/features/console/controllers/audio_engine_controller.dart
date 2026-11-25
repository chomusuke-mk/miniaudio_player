import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import 'package:open_file/open_file.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/models/mock_data.dart';
import 'recording_path_helper.dart';

/// Scoped [ChangeNotifier] used by [AudioEngineController] to isolate UI
/// rebuilds to individual control domains.
class _DomainNotifier extends ChangeNotifier {
  /// Notifies all listeners registered on this domain notifier.
  void notify() => notifyListeners();
}

/// Studio Master Console Engine Controller powered directly by [MiniaudioPlayer].
///
/// Manages dual-deck audio threads, automated crossfades, a reorderable
/// playlist queue, DSP effects (equalizer, reverb, limiter, silence skipping,
/// and crossfeed), multi-output matrix routing, multi-capture input routing
/// with ducking, live recording, and RAM-backed sound effects.
class AudioEngineController extends ChangeNotifier {
  /// Creates an [AudioEngineController].
  ///
  /// Optional [fileOpener] and [recordingDownloader] overrides may be supplied
  /// to intercept native file opening or Web recording downloads in tests.
  AudioEngineController({this.fileOpener, this.recordingDownloader});

  /// Optional override used to open the last recording on native targets in
  /// tests.
  ///
  /// Receives the target file [path] and optional MIME [type].
  final Future<OpenResult> Function(String path, {String? type})? fileOpener;

  /// Optional override used to trigger Web downloads in tests.
  ///
  /// Receives the completed [result] and optional target [fileName].
  final Future<bool> Function(RecordingResult result, {String? fileName})?
  recordingDownloader;

  /// Underlying [MiniaudioPlayer] instance driving audio playback, DSP,
  /// routing, and recording.
  final MiniaudioPlayer<AudioTrack> engine = MiniaudioPlayer<AudioTrack>(
    config: PlayerConfig(
      crossfade: CrossfadeConfig(
        autoDuration: const Duration(seconds: 5),
        manualDuration: const Duration(milliseconds: 100),
        curve: CrossfadeCurve.equalPower,
      ),
    ),
  );

  /// Scoped notifier for active track selection updates.
  final _DomainNotifier _trackSelectionNotifier = _DomainNotifier();

  /// Scoped notifier for waveform point updates.
  final _DomainNotifier _waveformNotifier = _DomainNotifier();

  /// Scoped notifier for transport control updates such as volume, rate, and
  /// pitch.
  final _DomainNotifier _transportControlsNotifier = _DomainNotifier();

  /// Scoped notifier for recording configuration, state, and results.
  final _DomainNotifier _recordingNotifier = _DomainNotifier();

  /// Scoped notifier for playlist queue and crossfade configuration updates.
  final _DomainNotifier _queueNotifier = _DomainNotifier();

  /// Scoped notifier for output/input routing and ducking updates.
  final _DomainNotifier _routingNotifier = _DomainNotifier();

  /// Scoped notifier for visualizer toggle and audio source updates.
  final _DomainNotifier _visualizerControlsNotifier = _DomainNotifier();

  /// Scoped notifier for ReplayGain configuration updates.
  final _DomainNotifier _replayGainNotifier = _DomainNotifier();

  /// Scoped notifier for limiter state updates.
  final _DomainNotifier _limiterNotifier = _DomainNotifier();

  /// Scoped notifier for mono downmix state updates.
  final _DomainNotifier _monoNotifier = _DomainNotifier();

  /// Scoped notifier for preamp gain updates.
  final _DomainNotifier _preampNotifier = _DomainNotifier();

  /// Scoped notifier for stereo balance updates.
  final _DomainNotifier _balanceNotifier = _DomainNotifier();

  /// Scoped notifier for pause-on-device-change policy updates.
  final _DomainNotifier _pauseOnDeviceChangeNotifier = _DomainNotifier();

  /// Scoped notifier for live metadata stream toggle updates.
  final _DomainNotifier _metadataEnabledNotifier = _DomainNotifier();

  /// Scoped notifier for silence-skipping configuration and saved-time
  /// updates.
  final _DomainNotifier _silenceNotifier = _DomainNotifier();

  /// Scoped notifier for Bauer stereophonic-to-binaural crossfeed updates.
  final _DomainNotifier _crossfeedNotifier = _DomainNotifier();

  /// Scoped notifier for spatializer width and enabled state updates.
  final _DomainNotifier _spatializerNotifier = _DomainNotifier();

  /// Scoped notifier for reverb preset and parameter updates.
  final _DomainNotifier _reverbNotifier = _DomainNotifier();

  /// Scoped notifier for equalizer band, preset, and enabled state updates.
  final _DomainNotifier _equalizerNotifier = _DomainNotifier();

  /// All domain notifiers managed and disposed by this controller.
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

  /// Listenable triggered when the selected track or loading state changes.
  Listenable get trackSelectionListenable => _trackSelectionNotifier;

  /// Listenable triggered when waveform sample points change.
  Listenable get waveformListenable => _waveformNotifier;

  /// Listenable triggered when transport controls (volume, rate, pitch) change.
  Listenable get transportControlsListenable => _transportControlsNotifier;

  /// Listenable triggered when live recording state, options, or results
  /// change.
  Listenable get recordingListenable => _recordingNotifier;

  /// Listenable triggered when queue items, ordering, or crossfade settings
  /// change.
  Listenable get queueListenable => _queueNotifier;

  /// Listenable triggered when output/input routing or ducking state changes.
  Listenable get routingListenable => _routingNotifier;

  /// Listenable triggered when visualizer toggle or source settings change.
  Listenable get visualizerControlsListenable => _visualizerControlsNotifier;

  /// Listenable triggered when ReplayGain mode or fallback gain changes.
  Listenable get replayGainListenable => _replayGainNotifier;

  /// Listenable triggered when the output limiter toggle changes.
  Listenable get limiterListenable => _limiterNotifier;

  /// Listenable triggered when mono downmix changes.
  Listenable get monoListenable => _monoNotifier;

  /// Listenable triggered when preamp gain changes.
  Listenable get preampListenable => _preampNotifier;

  /// Listenable triggered when stereo balance changes.
  Listenable get balanceListenable => _balanceNotifier;

  /// Listenable triggered when the pause-on-device-change setting changes.
  Listenable get pauseOnDeviceChangeListenable => _pauseOnDeviceChangeNotifier;

  /// Listenable triggered when live metadata parsing is toggled.
  Listenable get metadataEnabledListenable => _metadataEnabledNotifier;

  /// Listenable triggered when silence-skipping configuration or saved
  /// duration changes.
  Listenable get silenceListenable => _silenceNotifier;

  /// Listenable triggered when crossfeed parameters change.
  Listenable get crossfeedListenable => _crossfeedNotifier;

  /// Listenable triggered when spatializer width or enabled state changes.
  Listenable get spatializerListenable => _spatializerNotifier;

  /// Listenable triggered when reverb preset or parameters change.
  Listenable get reverbListenable => _reverbNotifier;

  /// Listenable triggered when equalizer bands, preset, or enabled state
  /// change.
  Listenable get equalizerListenable => _equalizerNotifier;

  /// Set of RPC keys currently awaiting completion from the engine.
  final Set<String> _inFlightRpcs = {};

  /// Latest pending RPC callbacks keyed by coalescing identifier.
  final Map<String, Future<void> Function()> _pendingRpcs = {};

  /// Checks whether an RPC identified by [key] is either in-flight or queued.
  bool _isRpcActive(String key) =>
      _inFlightRpcs.contains(key) || _pendingRpcs.containsKey(key);

  /// Notifies the optional [domain] notifier and any root controller listeners
  /// unless the controller has been disposed.
  void _notifyDomain([_DomainNotifier? domain]) {
    if (_isDisposed) return;
    domain?.notify();
    if (hasListeners) {
      super.notifyListeners();
    }
  }

  /// Serializes high-frequency RPC updates per [key], dropping intermediate
  /// superseded values while guaranteeing the latest [send] callback is
  /// dispatched.
  ///
  /// Invokes [onSettled] in a `finally` block once all queued work for [key]
  /// completes.
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

  /// Applies an optimistic local override via [applyOverride], notifies
  /// [domain], and dispatches [send] through [_coalesceRpc] under [rpcKey].
  ///
  /// Runs [onSettled] once the coalesced RPC sequence finishes.
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

  /// Synchronizes an optimistic override with an incoming engine stream event.
  ///
  /// Skips clearing when [rpcKey] still has an active RPC. Otherwise invokes
  /// [clearOverride], compares [readDisplayed] before and after clearing, and
  /// notifies [domain] if the displayed value changed.
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

  /// Whether [dispose] has been called on this controller.
  bool _isDisposed = false;

  /// Whether [init] has finished loading initial tracks and binding streams.
  bool _isReady = false;

  /// Whether a track selection transition is currently in flight.
  bool _isLoadingTrack = false;

  /// Locally cached list of available [AudioTrack] items.
  List<AudioTrack> _cachedTracks = [];

  /// Active waveform amplitude samples for the selected track, or `null` to
  /// fall back to [_sinusoidalWaveform].
  List<double>? _waveformPoints;

  /// Cached waveform sample lists keyed by [AudioTrack.id].
  final Map<String, List<double>> _waveformCache = {};

  /// Normalized waveform amplitude points for the currently selected track.
  List<double> get waveformPoints => _waveformPoints ?? _sinusoidalWaveform;

  /// Default fallback sinusoidal waveform generated once for unanalyzed tracks.
  static final List<double> _sinusoidalWaveform = _generateSinusoidalWaveform();

  /// Generates a smooth synthetic waveform curve containing [points] samples.
  static List<double> _generateSinusoidalWaveform({int points = 72}) {
    return List.generate(points, (i) {
      final t = i / (points - 1);
      final envelope = sin(pi * t);
      final wave =
          0.52 + 0.36 * sin(2 * pi * t * 3.5) + 0.12 * sin(2 * pi * t * 7.0);
      return (wave * (0.35 + 0.65 * envelope)).clamp(0.08, 0.98);
    });
  }

  /// Updates the cached waveform [points] for [trackId] (or the currently
  /// selected track when [trackId] is `null`) and notifies listeners if active.
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

  /// Resets [waveformPoints] back to the default sinusoidal fallback curve.
  void resetWaveformToSinusoidal() {
    if (_waveformPoints != null) {
      _waveformPoints = null;
      _notifyDomain(_waveformNotifier);
    }
  }

  /// Checks whether waveform points have been cached in the controller for
  /// [trackId].
  bool hasCachedWaveform(String trackId) => _waveformCache.containsKey(trackId);

  /// Retrieves the cached waveform points for [trackId], or `null` if
  /// unanalyzed.
  List<double>? getCachedWaveform(String trackId) => _waveformCache[trackId];

  /// Optimistic local override for [preampDb] while a preamp RPC is in flight.
  double? _preampOverride;

  /// Current preamp gain in decibels.
  double get preampDb => _preampOverride ?? engine.state.preamp;

  /// Sets the master preamp gain to [db] decibels.
  Future<void> setPreamp(double db) {
    MapLogger.debug('[DSP:PREAMP] Preamp gain set to ${db.toStringAsFixed(1)} dB');
    return _setOptimisticScalar(
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
  }

  /// Whether ReplayGain volume normalization is currently active in the engine.
  bool get replayGainEnabled => engine.state.volumeNormalization;

  /// Optimistic local override for [replayGainMode].
  ReplayGainMode? _replayGainModeOverride;

  /// Current ReplayGain operating mode.
  ReplayGainMode get replayGainMode =>
      _replayGainModeOverride ?? engine.state.replayGainMode;

  /// Fallback gain in decibels applied when tracks lack ReplayGain tags.
  double get defaultReplayGain => engine.state.defaultReplayGain;

  /// Sets the ReplayGain operating [mode].
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

  /// Sets the fallback ReplayGain target level to [gainDb] decibels.
  Future<void> setDefaultReplayGain(double gainDb) async {
    MapLogger.info(
      '[REPLAY_GAIN:DEFAULT] Fallback target gain set to: $gainDb dB',
    );
    await engine.action.setDefaultReplayGain(gainDb);
    _notifyDomain(_replayGainNotifier);
  }

  /// Identifier of the active equalizer preset (`'flat'`, `'custom'`, etc.).
  String _selectedPreset = 'flat';

  /// Optimistic local override for [currentEqualizer].
  Equalizer? _equalizerOverride;

  /// Display name of the active reverb preset (`'Studio'`, `'Custom'`, etc.).
  String _selectedReverbPreset = 'Studio';

  /// Optimistic local override for [currentReverb].
  Reverb? _reverbOverride;

  /// Last non-off reverb configuration preserved when reverb is toggled off.
  Reverb _lastActiveReverb = Reverb.studio;

  /// Active stream subscriptions bound to [engine] events.
  final List<StreamSubscription<dynamic>> _subscriptions = [];

  /// Whether the controller has completed initial setup.
  bool get isReady => _isReady;

  /// Whether a track selection operation is currently in progress.
  bool get isLoadingTrack => _isLoadingTrack;

  /// Locally tracked active [AudioTrack] during transitions or fallback.
  AudioTrack? _currentTrack;

  /// Identifier of the last track broadcast through [_trackSelectionNotifier].
  String? _lastNotifiedTrackId;

  /// Identifiers of the last queue snapshot broadcast through [_queueNotifier].
  List<String>? _lastNotifiedQueueIds;

  /// Last observed ReplayGain normalization flag used to deduplicate updates.
  bool _lastReplayGainEnabled = false;

  /// Last observed recording state used to deduplicate recording notifications.
  bool _lastIsRecording = false;

  /// Last observed input ducking state used to deduplicate routing updates.
  bool _lastIsDuckingActive = false;

  /// Last observed saved silence duration rounded to tenths of a second.
  int _lastSilenceSavedTenths = -1;

  /// Currently active or selected [AudioTrack], or `null` if none is loaded.
  AudioTrack? get selectedTrack {
    if (_isLoadingTrack && _currentTrack != null) return _currentTrack;
    final cur = engine.state.currentItem;
    if (cur != null && cur.data != null) return cur.data;
    if (_currentTrack != null) return _currentTrack;
    if (_cachedTracks.isNotEmpty) return _cachedTracks.first;
    return null;
  }

  /// List of tracks currently in the engine queue, or [_cachedTracks] when
  /// empty.
  List<AudioTrack> get availableTracks {
    final queue = engine.state.queue;
    if (queue.isNotEmpty) {
      return queue.where((i) => i.data != null).map((i) => i.data!).toList();
    }
    return _cachedTracks;
  }

  /// Optimistic local override for [crossfadeConfig].
  CrossfadeConfig? _crossfadeOverride;

  /// Active crossfade configuration for automatic and manual transitions.
  CrossfadeConfig get crossfadeConfig =>
      _crossfadeOverride ?? engine.state.crossfadeConfig;

  /// Whether queue shuffle is enabled.
  bool get isShuffle => engine.state.isShuffled;

  /// Whether any loop mode other than [LoopMode.off] is active.
  bool get isLoop => engine.state.loopMode != LoopMode.off;

  /// Current queue loop mode.
  LoopMode get loopMode => engine.state.loopMode;

  /// Current 10-band equalizer configuration.
  Equalizer get currentEqualizer =>
      _equalizerOverride ?? engine.state.equalizer;

  /// Whether the equalizer DSP stage is enabled.
  bool get equalizerEnabled => currentEqualizer.enabled;

  /// Name key of the currently selected equalizer preset.
  String get selectedPreset => _selectedPreset;

  /// Current reverb configuration, retaining last active parameters when
  /// disabled.
  Reverb get currentReverb {
    if (_reverbOverride != null) return _reverbOverride!;
    final rev = engine.state.reverb;
    if (rev == Reverb.off) {
      return _lastActiveReverb.copyWith(enabled: false);
    }
    return rev;
  }

  /// Name of the currently selected reverb preset.
  String get selectedReverbPreset => _selectedReverbPreset;

  /// Current reverb room size parameter (`0.0` to `1.0`).
  double get reverbRoomSize => currentReverb.roomSize;

  /// Current reverb high-frequency damping parameter (`0.0` to `1.0`).
  double get reverbDamping => currentReverb.damping;

  /// Current reverb stereo width parameter (`0.0` to `1.0`).
  double get reverbWidth => currentReverb.width;

  /// Current reverb wet signal level (`0.0` to `1.0`).
  double get reverbWet => currentReverb.wet;

  /// Current reverb dry signal level (`0.0` to `1.0`).
  double get reverbDry => currentReverb.dry;

  /// Alias for [reverbWet] representing wet/dry balance.
  double get reverbWetDry => currentReverb.wet;

  /// Whether the reverb DSP stage is enabled.
  bool get reverbEnabled => currentReverb.enabled;

  /// Optimistic local override for [crossfeed].
  Crossfeed? _crossfeedOverride;

  /// Current headphone crossfeed DSP configuration.
  Crossfeed get crossfeed => _crossfeedOverride ?? engine.state.crossfeed;

  /// Optimistic local override for [spatializerEnabled].
  bool? _spatializerEnabledOverride;

  /// Optimistic local override for [spatializerWidth].
  double? _spatializerWidthOverride;

  /// Current stereo spatializer width factor.
  double get spatializerWidth =>
      _spatializerWidthOverride ?? engine.state.spatializerWidth;

  /// Whether the stereo spatializer DSP stage is enabled.
  bool get spatializerEnabled =>
      _spatializerEnabledOverride ?? engine.state.spatializerEnabled;

  /// Optimistic local override for [stereoBalance].
  double? _stereoBalanceOverride;

  /// Current left-right stereo balance (`-1.0` left to `1.0` right).
  double get stereoBalance => _stereoBalanceOverride ?? engine.state.balance;

  /// Optimistic local override for [monoDownmix].
  bool? _monoOverride;

  /// Whether stereo-to-mono downmix is enabled.
  bool get monoDownmix => _monoOverride ?? engine.state.mono;

  /// Optimistic local override for [limiterEnabled].
  bool? _limiterOverride;

  /// Whether the master output limiter is enabled.
  bool get limiterEnabled => _limiterOverride ?? engine.state.limiterEnabled;

  /// Last non-disabled [SilenceSkipMode] remembered across toggles.
  SilenceSkipMode _silenceMode = SilenceSkipMode.all;

  /// Optimistic local override for [_effectiveSilenceConfig].
  SilenceSkipConfig? _silenceConfigOverride;

  /// Effective silence-skipping configuration combining local overrides and
  /// engine state.
  SilenceSkipConfig get _effectiveSilenceConfig =>
      _silenceConfigOverride ?? engine.state.silenceConfig;

  /// Whether silence skipping is currently enabled.
  bool get silenceEnabled =>
      _effectiveSilenceConfig.mode != SilenceSkipMode.disabled;

  /// Active or remembered [SilenceSkipMode].
  SilenceSkipMode get silenceMode =>
      _effectiveSilenceConfig.mode != SilenceSkipMode.disabled
      ? _effectiveSilenceConfig.mode
      : _silenceMode;

  /// Silence detection threshold in decibels.
  double get silenceThresholdDb => _effectiveSilenceConfig.thresholdDb;

  /// Minimum contiguous silence duration in milliseconds before skipping.
  int get minSilenceDurationMs =>
      _effectiveSilenceConfig.minSilenceDuration.inMilliseconds;

  /// Audio padding preserved around skipped silence regions in milliseconds.
  int get silencePaddingMs => _effectiveSilenceConfig.padding.inMilliseconds;

  /// Total playback time saved by silence skipping.
  Duration get silenceSavedDuration => engine.state.silenceSavedDuration;

  /// Optimistic local override for [visualizerEnabled].
  bool? _visualizerEnabledOverride;

  /// Whether the real-time FFT visualizer stream is enabled.
  bool get visualizerEnabled =>
      _visualizerEnabledOverride ?? engine.state.visualizerEnabled;

  /// Optimistic local override for [visualizerSource].
  AudioOutputSource? _visualizerSourceOverride;

  /// Audio feed routed into the FFT visualizer analyzer.
  AudioOutputSource get visualizerSource =>
      _visualizerSourceOverride ?? engine.state.visualizerSource;

  /// Optimistic local override for [metadataEnabled].
  bool? _metadataEnabledOverride;

  /// Whether live stream metadata extraction is enabled.
  bool get metadataEnabled =>
      _metadataEnabledOverride ?? engine.state.metadataEnabled;

  /// Total native RAM currently allocated by preloaded sound effects in bytes.
  int get allocatedRamBytes => engine.state.allocatedRamBytes;

  /// Identifiers of sound effects currently loaded in native RAM.
  List<String> get loadedEffectIds => engine.state.loadedEffectIds;

  /// Number of polyphonic sound effect voices currently playing.
  int get activeVoicesCount => engine.state.activeVoicesCount;

  /// Optimistic local override for [volume].
  double? _volumeOverride;

  /// Master playback volume (`0.0` to `1.0`).
  double get volume => _volumeOverride ?? engine.state.volume;

  /// Optimistic local override for [rate].
  double? _rateOverride;

  /// Playback speed multiplier.
  double get rate => _rateOverride ?? engine.state.rate;

  /// Optimistic local override for [pitch].
  double? _pitchOverride;

  /// Pitch shift multiplier independent of playback rate.
  double get pitch => _pitchOverride ?? engine.state.pitch;

  /// Available audio output devices reported by the engine.
  List<AudioDevice> get audioDevices => engine.state.globalOutputDevices;

  /// Available audio capture input devices reported by the engine.
  List<AudioDevice> get inputDevices => engine.state.globalInputDevices;

  /// Currently active output endpoints.
  Set<AudioOutput> get outputs => engine.state.outputs;

  /// Currently active capture input endpoints.
  Set<AudioInput> get inputs => engine.state.inputs;

  /// Cached per-device capture input configurations keyed by device ID.
  final Map<String, AudioInputConfig> _inputConfigs = {};

  /// Returns the saved [AudioInputConfig] for [deviceId], or a default
  /// instance if none has been configured yet.
  AudioInputConfig getInputConfig(String deviceId) =>
      _inputConfigs[deviceId] ?? const AudioInputConfig();

  /// Optimistic local override for [pauseOnDeviceChange].
  bool? _pauseOnDeviceChangeOverride;

  /// Whether playback automatically pauses when the default audio output device
  /// changes.
  bool get pauseOnDeviceChange =>
      _pauseOnDeviceChangeOverride ?? engine.state.pauseOnDeviceChange;

  /// Whether the engine is currently recording audio.
  bool get isRecording => engine.state.isRecording;

  /// Elapsed duration of the current recording session.
  Duration get recordedDuration => engine.state.recordedDuration;

  /// Target file container format for new recordings.
  AudioFileFormat _recordingFormat = AudioFileFormat.wav;

  /// Active target file container format selected for new recordings.
  AudioFileFormat get recordingFormat => _recordingFormat;

  /// Audio bus source captured during recording.
  AudioOutputSource _recordingSource = AudioOutputSource.all;

  /// Audio bus source captured during recording.
  AudioOutputSource get recordingSource => _recordingSource;

  /// Whether Web recordings are written to OPFS instead of an in-memory buffer.
  bool _useWebOpfs = false;

  /// Whether Web recordings target OPFS storage instead of an in-memory buffer.
  bool get useWebOpfs => _useWebOpfs;

  /// Most recent completed [RecordingResult], if any.
  RecordingResult? _lastRecordingResult;

  /// Most recent completed [RecordingResult], or `null` when unavailable.
  RecordingResult? get lastRecordingResult => _lastRecordingResult;

  /// Error message from the most recent recording failure, if any.
  String? _lastRecordingError;

  /// Error message from the most recent failed recording operation, or `null`.
  String? get lastRecordingError => _lastRecordingError;

  /// Updates the active recording container format to [fmt].
  void setRecordingFormat(AudioFileFormat fmt) {
    if (_recordingFormat == fmt) return;
    _recordingFormat = fmt;
    MapLogger.debug(
      '[RECORDING:FORMAT] Recording format set to: ${fmt.name.toUpperCase()}',
    );
    _notifyDomain(_recordingNotifier);
  }

  /// Updates the audio bus captured during recording to [src].
  void setRecordingSource(AudioOutputSource src) {
    if (_recordingSource == src) return;
    _recordingSource = src;
    MapLogger.debug(
      '[RECORDING:SOURCE] Recording source set to: ${src.name.toUpperCase()}',
    );
    _notifyDomain(_recordingNotifier);
  }

  /// Sets whether Web recordings use OPFS storage when [enabled] is `true`.
  void setUseWebOpfs(bool enabled) {
    if (_useWebOpfs == enabled) return;
    _useWebOpfs = enabled;
    MapLogger.debug(
      '[RECORDING:OPFS] Web OPFS target ${enabled ? "ENABLED" : "DISABLED"}',
    );
    _notifyDomain(_recordingNotifier);
  }

  /// Canonical file name (including extension) of the most recent completed
  /// recording.
  String? get lastRecordingFileName => _lastRecordingResult?.fileName;

  /// Canonical destination path of the most recent completed recording (`null`
  /// on Web in-memory recordings).
  String? get lastRecordingOpenTarget {
    final res = _lastRecordingResult;
    if (res == null || res.path.isEmpty) return null;
    return res.path;
  }

  /// Starts a live audio recording session.
  ///
  /// Uses [customPath] when non-empty; otherwise writes to an OPFS path or
  /// [MemoryRecordingBuffer] on Web, or creates a temporary local file via
  /// [createTempRecordingFilePath] on native targets.
  Future<void> startRecording({String? customPath}) async {
    _lastRecordingError = null;
    final activeFmt = _recordingFormat;
    final fileName =
        'studio_recording_${DateTime.now().millisecondsSinceEpoch}.${activeFmt.extension}';

    MapLogger.info(
      '[RECORDING:START] Starting recording (format=${activeFmt.name}, '
      'source=${_recordingSource.name}, webOpfs=$_useWebOpfs)',
    );

    try {
      if (kIsWeb) {
        final effectivePath =
            (customPath != null && customPath.trim().isNotEmpty)
            ? customPath.trim()
            : (_useWebOpfs ? 'recordings/$fileName' : null);
        if (effectivePath != null) {
          await engine.action.startRecording(
            effectivePath,
            format: activeFmt,
            source: _recordingSource,
          );
        } else {
          final memBuf = MemoryRecordingBuffer(path: fileName);
          await engine.action.startRecordingToBuffer(
            memBuf,
            format: activeFmt,
            source: _recordingSource,
          );
        }
      } else {
        final targetPath = (customPath != null && customPath.trim().isNotEmpty)
            ? customPath.trim()
            : await createTempRecordingFilePath(fileName);
        await engine.action.startRecording(
          targetPath,
          format: activeFmt,
          source: _recordingSource,
        );
      }
      _notifyDomain(_recordingNotifier);
    } catch (e) {
      if (e is MiniaudioPlayerException &&
          e.errorCode == MapResult.errorUnsupported &&
          kIsWeb &&
          _useWebOpfs) {
        _lastRecordingError =
            'OPFS is not supported in this browser/context. Disable "Use OPFS" to record into memory instead.';
      } else {
        _lastRecordingError = e.toString();
      }
      MapLogger.error(
        '[RECORDING:ERROR] Failed to start recording: $_lastRecordingError',
      );
      _notifyDomain(_recordingNotifier);
      rethrow;
    }
  }

  /// Stops the active recording session and returns the completed
  /// [RecordingResult].
  Future<RecordingResult> stopRecording() async {
    MapLogger.info('[RECORDING:STOP] Stopping live recording...');
    try {
      final res = await engine.action.stopRecording();
      _lastRecordingResult = res;
      _lastRecordingError = null;
      MapLogger.info(
        '[RECORDING:STOP] Recording saved: "${res.fileName}" '
        '(${res.path.isEmpty ? "in-memory" : res.path})',
      );
      _notifyDomain(_recordingNotifier);
      return res;
    } catch (e) {
      _lastRecordingError = e.toString();
      MapLogger.error('[RECORDING:ERROR] Failed to stop recording: $e');
      _notifyDomain(_recordingNotifier);
      rethrow;
    }
  }

  /// Triggers a browser download via [RecordingResult.download] on Web, or
  /// opens the saved file via [openLastRecording] on native targets.
  Future<bool> downloadLastRecording() async {
    final res = _lastRecordingResult;
    if (res == null) return false;
    MapLogger.info('[RECORDING:DOWNLOAD] Exporting "${res.fileName}"');
    final downloader = recordingDownloader;
    if (downloader != null) {
      return await downloader(res, fileName: res.fileName);
    }
    if (kIsWeb) {
      return await res.download();
    }
    final openRes = await openLastRecording();
    return openRes.type == ResultType.done;
  }

  /// Opens the most recent completed recording via `OpenFile.open` on native
  /// targets, or triggers a direct download via [RecordingResult.download] on
  /// Web.
  Future<OpenResult> openLastRecording() async {
    final res = _lastRecordingResult;
    if (res == null || (!kIsWeb && res.path.isEmpty)) {
      MapLogger.warn(
        '[RECORDING:OPEN] Cannot open recording: no recording available.',
      );
      return OpenResult(
        type: ResultType.fileNotFound,
        message: 'No openable recording available.',
      );
    }
    if (kIsWeb) {
      final ok = await downloadLastRecording();
      return OpenResult(
        type: ok ? ResultType.done : ResultType.error,
        message: ok ? 'done' : 'Browser download unavailable.',
      );
    }
    MapLogger.info('[RECORDING:OPEN] Opening recording file "${res.path}"');
    final opener = fileOpener;
    return opener != null
        ? await opener(res.path, type: res.mimeType)
        : await OpenFile.open(res.path, type: res.mimeType);
  }

  /// Enqueues and starts playing [lastRecordingResult] directly via
  /// [RecordingResult.toAudioSource].
  Future<void> playLastRecording() async {
    final res = _lastRecordingResult;
    if (res == null) return;
    MapLogger.info('[RECORDING:PLAY] Enqueuing recording "${res.fileName}"');
    final src = res.toAudioSource<AudioTrack>();
    final track = AudioTrack(
      id: 'rec_${DateTime.now().microsecondsSinceEpoch}',
      title: res.fileName,
      source: src,
      artist: res.isOpfs
          ? 'OPFS Recording'
          : (res.isInMemory ? 'Memory Recording' : 'Disk Recording'),
    );
    await addTrack(track);
  }

  /// Deletes the most recent recording from OPFS, disk, or memory via
  /// [RecordingResult.delete].
  Future<bool> deleteLastRecording() async {
    final res = _lastRecordingResult;
    if (res == null) return false;
    final deleted = await res.delete();
    MapLogger.info(
      '[RECORDING:DELETE] Deleted recording "${res.fileName}" (deleted=$deleted)',
    );
    if (deleted || !await res.exists()) {
      _lastRecordingResult = null;
      _notifyDomain(_recordingNotifier);
    }
    return deleted;
  }

  /// Initializes the controller by loading sample tracks, binding engine
  /// streams, configuring initial DSP defaults, and preloading RAM sound
  /// effects.
  Future<void> init() async {
    MapLogger.info('[ENGINE:INIT] Initializing AudioEngineController...');
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
      } catch (e) {
        MapLogger.warn('[ENGINE:INIT] Failed to populate initial queue: $e');
      }
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
    } catch (e) {
      MapLogger.warn(
        '[ENGINE:INIT] Failed to apply default engine configuration: $e',
      );
    }
    if (_isDisposed) return;

    // Load sample effects in the background so the console can mount immediately
    unawaited(loadSampleEffects());
    MapLogger.info(
      '[ENGINE:INIT] AudioEngineController ready (${_cachedTracks.length} tracks loaded).',
    );
    _notifyDomain();
  }

  /// Compares two [CrossfadeConfig] instances [a] and [b] by value.
  static bool _crossfadeEquals(CrossfadeConfig a, CrossfadeConfig b) =>
      a.curve == b.curve &&
      a.autoDuration == b.autoDuration &&
      a.manualDuration == b.manualDuration;

  /// Compares two [SilenceSkipConfig] instances [a] and [b] by value.
  static bool _silenceConfigEquals(SilenceSkipConfig a, SilenceSkipConfig b) =>
      a.enabled == b.enabled &&
      a.mode == b.mode &&
      a.thresholdDb == b.thresholdDb &&
      a.minSilenceDuration == b.minSilenceDuration &&
      a.padding == b.padding;

  /// Subscribes to all relevant [engine] streams and routes state changes to
  /// their scoped domain notifiers.
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
      engine.stream.errors.listen((err) {
        if (err.message.toLowerCase().contains('record')) {
          MapLogger.error('[RECORDING:ERROR] ${err.message}');
          _lastRecordingError = err.message;
          _notifyDomain(_recordingNotifier);
        } else {
          MapLogger.error('[ENGINE:ERROR] ${err.message}');
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

  /// Toggles an output endpoint for [device] on or off using [source] when
  /// enabling.
  Future<void> toggleOutput(
    AudioDevice device, {
    AudioOutputSource source = AudioOutputSource.all,
  }) async {
    final curOutputs = Set<AudioOutput>.of(engine.state.outputs);
    final exists = curOutputs.any((o) => o.deviceId == device.id);
    MapLogger.info(
      '[ROUTING:OUTPUT] ${exists ? "Removing" : "Adding"} output '
      '"${device.name}" (${device.id}, source=${source.name})',
    );
    if (exists) {
      curOutputs.removeWhere((o) => o.deviceId == device.id);
    } else {
      curOutputs.add(AudioOutput(deviceId: device.id, source: source));
    }
    await engine.action.setOutputs(curOutputs);
    _notifyDomain(_routingNotifier);
  }

  /// Updates the [AudioOutputSource] routed to the active output matching
  /// [deviceId] to [source].
  Future<void> setOutputSource(
    String deviceId,
    AudioOutputSource source,
  ) async {
    MapLogger.info(
      '[ROUTING:OUTPUT] Setting output "$deviceId" source to ${source.name}',
    );
    final curOutputs = engine.state.outputs.map((o) {
      if (o.deviceId == deviceId) {
        return AudioOutput(deviceId: o.deviceId, source: source);
      }
      return o;
    }).toSet();
    await engine.action.setOutputs(curOutputs);
    _notifyDomain(_routingNotifier);
  }

  /// Toggles an audio capture input endpoint for [device] on or off.
  Future<void> toggleInput(AudioDevice device) async {
    final curInputs = Set<AudioInput>.of(engine.state.inputs);
    final exists = curInputs.any((i) => i.deviceId == device.id);
    MapLogger.info(
      '[ROUTING:INPUT] ${exists ? "Removing" : "Adding"} input '
      '"${device.name}" (${device.id})',
    );
    if (exists) {
      curInputs.removeWhere((i) => i.deviceId == device.id);
    } else {
      final config = getInputConfig(device.id);
      curInputs.add(AudioInput(deviceId: device.id, config: config));
    }
    await engine.action.setInputs(curInputs);
    _notifyDomain(_routingNotifier);
  }

  /// Saves [config] for capture input [deviceId] and applies it immediately if
  /// the device is currently active.
  Future<void> configureInputDevice(
    String deviceId,
    AudioInputConfig config,
  ) async {
    MapLogger.debug('[ROUTING:INPUT] Updating config for input "$deviceId"');
    _inputConfigs[deviceId] = config;
    if (engine.state.inputs.any((i) => i.deviceId == deviceId)) {
      await engine.action.configureInput(config, deviceId: deviceId);
    }
    _notifyDomain(_routingNotifier);
  }

  /// Detects the built-in equalizer preset key matching [eq], or returns `null`
  /// for custom curves.
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

  /// Optimistically applies [target] as the active [Equalizer] configuration
  /// and sends it to the engine.
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

  /// Enables or disables the equalizer DSP stage according to [enabled].
  Future<void> setEqualizerEnabled(bool enabled) async {
    MapLogger.info(
      '[DSP:EQ] Equalizer ${enabled ? "ENABLED" : "DISABLED"}',
    );
    await _applyEqualizer(currentEqualizer.copyWith(enabled: enabled));
  }

  /// Applies the built-in equalizer preset identified by [presetKey].
  Future<void> setEqualizerPreset(String presetKey) async {
    MapLogger.info('[DSP:EQ] Equalizer preset selected: $presetKey');
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

  /// Sets the gain of equalizer band [bandIndex] to [gainDb] decibels.
  Future<void> setEqualizerBand(int bandIndex, double gainDb) async {
    final list = currentEqualizer.toList();
    if (bandIndex >= 0 && bandIndex < list.length) {
      MapLogger.debug(
        '[DSP:EQ] Band $bandIndex gain set to ${gainDb.toStringAsFixed(1)} dB',
      );
      list[bandIndex] = gainDb;
      await _applyEqualizer(
        Equalizer.fromList(list, enabled: currentEqualizer.enabled),
      );
    }
  }

  /// Detects the built-in reverb preset name matching [rev], or returns `null`
  /// for custom parameters.
  static String? _detectReverbPreset(Reverb rev) {
    for (final entry in Reverb.presets.entries) {
      if (entry.key == 'Off') continue;
      if (entry.value == rev) return entry.key;
    }
    return null;
  }

  /// Optimistically applies [target] as the active [Reverb] configuration and
  /// sends it to the engine.
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

  /// Enables or disables the reverb DSP stage according to [enabled].
  Future<void> toggleReverb(bool enabled) async {
    MapLogger.info(
      '[DSP:REVERB] Reverb ${enabled ? "ENABLED" : "DISABLED"}',
    );
    await _applyReverb(currentReverb.copyWith(enabled: enabled));
  }

  /// Applies the built-in reverb preset registered under [name].
  Future<void> setReverbPreset(String name) async {
    MapLogger.info('[DSP:REVERB] Reverb preset selected: $name');
    final preset = Reverb.presets[name] ?? Reverb.off;
    await _applyReverb(preset);
  }

  /// Updates individual reverb parameters ([roomSize], [damping], [width],
  /// [wet], [dry], and [enabled]) on top of [currentReverb].
  Future<void> setReverbParams({
    double? roomSize,
    double? damping,
    double? width,
    double? wet,
    double? dry,
    bool? enabled,
  }) async {
    MapLogger.debug(
      '[DSP:REVERB] Updating reverb params (enabled=${enabled ?? true})',
    );
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

  /// Monotonic counter used to discard stale async [selectTrack] operations.
  int _trackSelectionEpoch = 0;

  /// Selects [track] for playback, inserting it next if absent from the queue.
  ///
  /// When [autoPlay] is `true` and [track] is newly inserted, playback starts
  /// immediately after advancing to it.
  Future<void> selectTrack(AudioTrack track, {bool autoPlay = false}) async {
    final currentEpoch = ++_trackSelectionEpoch;
    final prevWaveform = _waveformPoints;
    _isLoadingTrack = true;
    _currentTrack = track;
    _lastNotifiedTrackId = track.id;
    _waveformPoints = _waveformCache[track.id];
    MapLogger.info(
      '[TRACK:SELECT] Selecting "${track.title}" (id=${track.id}, autoPlay=$autoPlay)',
    );
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
      MapLogger.error(
        '[TRACK:SELECT] Error selecting track "${track.title}" in engine: $e',
      );
    } finally {
      if (currentEpoch == _trackSelectionEpoch) {
        _isLoadingTrack = false;
        _notifyDomain(_trackSelectionNotifier);
      }
    }
  }

  /// Appends [track] to the playlist queue and begins playing it immediately.
  Future<void> addTrack(AudioTrack track) async {
    MapLogger.info(
      '[QUEUE:ADD] Appending track "${track.title}" (id=${track.id})',
    );
    _cachedTracks = [..._cachedTracks, track];
    final item = track.source.withData<AudioTrack>(track);
    await engine.action.append([item]);
    await engine.action.play(position: engine.state.queue.length - 1);
    _notifyDomain(_queueNotifier);
  }

  /// Moves a track in the queue from [oldIndex] to [newIndex].
  Future<void> reorderTrack(int oldIndex, int newIndex) async {
    MapLogger.debug(
      '[QUEUE:REORDER] Reordering track from index $oldIndex to $newIndex',
    );
    await engine.action.reorder(oldIndex, newIndex);
    _notifyDomain(_queueNotifier);
  }

  /// Toggles queue shuffle playback on or off.
  Future<void> toggleShuffle() async {
    final nextShuffle = !engine.state.isShuffled;
    MapLogger.info(
      '[TRANSPORT:SHUFFLE] Shuffle ${nextShuffle ? "ENABLED" : "DISABLED"}',
    );
    await engine.action.setShuffle(nextShuffle);
    _notifyDomain();
  }

  /// Cycles queue loop mode through [LoopMode.off], [LoopMode.all], and
  /// [LoopMode.one].
  Future<void> toggleLoop() async {
    final nextMode = engine.state.loopMode == LoopMode.off
        ? LoopMode.all
        : engine.state.loopMode == LoopMode.all
        ? LoopMode.one
        : LoopMode.off;
    MapLogger.info(
      '[TRANSPORT:LOOP] Loop mode changed to: ${nextMode.name.toUpperCase()}',
    );
    await engine.action.setLoopMode(nextMode);
    _notifyDomain();
  }

  /// Skips playback to the next track in the queue.
  Future<void> nextTrack() async {
    MapLogger.debug('[TRACK:NEXT] Skipping to next track');
    _currentTrack = null;
    resetWaveformToSinusoidal();
    try {
      await engine.action.next();
    } catch (e) {
      MapLogger.error('[TRACK:NEXT] Error skipping to next track: $e');
    }
    _notifyDomain(_trackSelectionNotifier);
  }

  /// Skips playback to the previous track in the queue.
  Future<void> previousTrack() async {
    MapLogger.debug('[TRACK:PREV] Skipping to previous track');
    _currentTrack = null;
    resetWaveformToSinusoidal();
    try {
      await engine.action.previous();
    } catch (e) {
      MapLogger.error('[TRACK:PREV] Error skipping to previous track: $e');
    }
    _notifyDomain(_trackSelectionNotifier);
  }

  /// Optimistically applies [target] as the active [CrossfadeConfig] and sends
  /// it to the engine.
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

  /// Sets the crossfade transition curve to [curve].
  Future<void> setCrossfadeCurve(CrossfadeCurve curve) {
    MapLogger.debug('[CROSSFADE:CURVE] Curve set to ${curve.name}');
    return _applyCrossfade(crossfadeConfig.copyWith(curve: curve));
  }

  /// Sets the automatic track-end crossfade duration to [duration].
  Future<void> setCrossfadeDuration(Duration duration) {
    MapLogger.debug(
      '[CROSSFADE:AUTO] Auto duration set to ${duration.inMilliseconds} ms',
    );
    return _applyCrossfade(crossfadeConfig.copyWith(autoDuration: duration));
  }

  /// Sets the manual skip/seek crossfade duration to [duration].
  Future<void> setManualCrossfadeDuration(Duration duration) {
    MapLogger.debug(
      '[CROSSFADE:MANUAL] Manual duration set to ${duration.inMilliseconds} ms',
    );
    return _applyCrossfade(crossfadeConfig.copyWith(manualDuration: duration));
  }

  /// Applies the headphone crossfeed configuration [cf].
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

  /// Enables or disables headphone crossfeed according to [enabled].
  Future<void> toggleCrossfeed(bool enabled) {
    MapLogger.info(
      '[DSP:CROSSFEED] Crossfeed ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return setCrossfeed(crossfeed.copyWith(enabled: enabled));
  }

  /// Sets the crossfeed low-pass cutoff frequency to [cutoffHz] Hertz.
  Future<void> setCrossfeedCutoff(double cutoffHz) {
    MapLogger.debug(
      '[DSP:CROSSFEED] Cutoff frequency set to ${cutoffHz.toStringAsFixed(0)} Hz',
    );
    return setCrossfeed(crossfeed.copyWith(cutoffHz: cutoffHz));
  }

  /// Sets the crossfeed interaural feed level to [feedDb] decibels.
  Future<void> setCrossfeedFeed(double feedDb) {
    MapLogger.debug(
      '[DSP:CROSSFEED] Feed level set to ${feedDb.toStringAsFixed(1)} dB',
    );
    return setCrossfeed(crossfeed.copyWith(feedDb: feedDb));
  }

  /// Enables or disables the stereo spatializer according to [enabled].
  Future<void> setSpatializerEnabled(bool enabled) {
    MapLogger.info(
      '[DSP:SPATIALIZER] Spatializer ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _setOptimisticScalar(
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
  }

  /// Sets the stereo spatializer width factor to [width].
  Future<void> setSpatializerWidth(double width) {
    MapLogger.debug(
      '[DSP:SPATIALIZER] Width set to ${width.toStringAsFixed(2)}',
    );
    return _setOptimisticScalar(
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
  }

  /// Sets the stereo left-right [balance] (`-1.0` to `1.0`).
  Future<void> setStereoBalance(double balance) {
    MapLogger.debug(
      '[DSP:BALANCE] Stereo balance set to ${balance.toStringAsFixed(2)}',
    );
    return _setOptimisticScalar(
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
  }

  /// Enables or disables stereo-to-mono downmix according to [enabled].
  Future<void> setMonoDownmix(bool enabled) {
    MapLogger.info(
      '[DSP:MONO] Mono downmix ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _setOptimisticScalar(
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
  }

  /// Enables or disables the master output limiter according to [enabled].
  Future<void> setLimiterEnabled(bool enabled) {
    MapLogger.info(
      '[DSP:LIMITER] Output limiter ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _setOptimisticScalar(
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
  }

  /// Optimistically applies [target] as the active [SilenceSkipConfig] and
  /// sends it to the engine.
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

  /// Enables or disables silence skipping according to [enabled].
  Future<void> setSilenceSkipEnabled(bool enabled) {
    MapLogger.info(
      '[DSP:SILENCE] Silence skipping ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _applySilenceConfig(
      _effectiveSilenceConfig.copyWith(
        enabled: enabled,
        mode: enabled ? _silenceMode : SilenceSkipMode.disabled,
        thresholdDb: silenceThresholdDb,
      ),
    );
  }

  /// Sets the silence skipping operating [mode].
  Future<void> setSilenceMode(SilenceSkipMode mode) {
    MapLogger.info('[DSP:SILENCE] Silence skip mode set to: ${mode.name}');
    return _applySilenceConfig(
      _effectiveSilenceConfig.copyWith(
        enabled: mode != SilenceSkipMode.disabled,
        mode: mode,
        thresholdDb: silenceThresholdDb,
      ),
    );
  }

  /// Sets the silence detection threshold to [thresholdDb] decibels.
  Future<void> setSilenceThresholdDb(double thresholdDb) {
    MapLogger.debug(
      '[DSP:SILENCE] Threshold set to ${thresholdDb.toStringAsFixed(1)} dB',
    );
    return _applySilenceConfig(
      _effectiveSilenceConfig.copyWith(
        enabled: silenceEnabled,
        mode: silenceEnabled ? _silenceMode : SilenceSkipMode.disabled,
        thresholdDb: thresholdDb,
      ),
    );
  }

  /// Sets the minimum contiguous silence duration to [durationMs] milliseconds.
  Future<void> setMinSilenceDurationMs(int durationMs) {
    MapLogger.debug(
      '[DSP:SILENCE] Minimum silence duration set to $durationMs ms',
    );
    return _applySilenceConfig(
      _effectiveSilenceConfig.copyWith(
        minSilenceDuration: Duration(milliseconds: durationMs),
      ),
    );
  }

  /// Sets the silence edge padding to [paddingMs] milliseconds.
  Future<void> setSilencePaddingMs(int paddingMs) {
    MapLogger.debug('[DSP:SILENCE] Padding set to $paddingMs ms');
    return _applySilenceConfig(
      _effectiveSilenceConfig.copyWith(
        padding: Duration(milliseconds: paddingMs),
      ),
    );
  }

  /// Enables or disables the real-time 10-band FFT visualizer stream according
  /// to [enabled].
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

  /// Sets the audio bus fed into the FFT visualizer to [source].
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

  /// Enables or disables live stream metadata extraction according to
  /// [enabled].
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

  /// Generates and preloads sample synthesized RAM sound effects into the
  /// engine's polyphonic SFX pool.
  Future<void> loadSampleEffects() async {
    if (_isDisposed) return;
    MapLogger.info('[SFX:LOAD] Preloading sample RAM sound effects...');
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
      MapLogger.info('[SFX:LOAD] Sample RAM sound effects loaded.');
      _notifyDomain();
    } catch (e) {
      if (!_isDisposed) {
        MapLogger.error('[SFX:LOAD] Failed to load sample sound effects: $e');
      }
    }
  }

  /// Triggers playback of the preloaded RAM sound effect identified by [id]
  /// with optional [volume] and [pitch] overrides.
  Future<Voice?> playSampleEffect(
    String id, {
    double volume = 1.0,
    double pitch = 1.0,
  }) async {
    MapLogger.debug(
      '[SFX:PLAY] Triggering effect "$id" (volume=$volume, pitch=$pitch)',
    );
    return await engine.action.playEffect(
      id,
      config: EffectConfig(volume: volume, pitch: pitch),
    );
  }

  /// Unloads all RAM sound effects from the engine and frees their allocated
  /// memory.
  Future<void> unloadAllEffects() async {
    MapLogger.info('[SFX:UNLOAD] Unloading all RAM sound effects');
    await engine.action.setEffects([]);
    _notifyDomain();
  }

  /// Reorders the playlist queue according to the monotonic item [ids] order.
  Future<void> reorderQueueByIds(List<int> ids) async {
    MapLogger.debug(
      '[QUEUE:REORDER] Reordering queue by IDs (${ids.length} items)',
    );
    await engine.action.reorderByIds(ids);
    _notifyDomain(_queueNotifier);
  }

  /// Reverses the current playlist queue order using monotonic item IDs.
  Future<void> reverseQueueByIds() async {
    final ids = engine.state.queue
        .where((s) => s.id != null)
        .map((s) => s.id!)
        .toList()
        .reversed
        .toList();
    if (ids.isNotEmpty) {
      MapLogger.debug(
        '[QUEUE:REORDER] Reversing queue order by IDs (${ids.length} items)',
      );
      await engine.action.reorderByIds(ids);
      _notifyDomain(_queueNotifier);
    }
  }

  /// Sets the master playback volume to [val] (`0.0` to `1.0`).
  Future<void> setVolume(double val) {
    MapLogger.debug(
      '[TRANSPORT:VOLUME] Volume set to ${val.toStringAsFixed(2)}',
    );
    return _setOptimisticScalar(
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
  }

  /// Sets the playback speed multiplier to [val].
  Future<void> setRate(double val) {
    MapLogger.debug(
      '[TRANSPORT:RATE] Playback rate set to ${val.toStringAsFixed(2)}x',
    );
    return _setOptimisticScalar(
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
  }

  /// Sets the pitch shift multiplier to [val].
  Future<void> setPitch(double val) {
    MapLogger.debug(
      '[TRANSPORT:PITCH] Pitch set to ${val.toStringAsFixed(2)}',
    );
    return _setOptimisticScalar(
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
  }

  /// Enables or disables automatic playback pause on audio output device
  /// changes according to [enabled].
  Future<void> setPauseOnDeviceChange(bool enabled) {
    MapLogger.info(
      '[ROUTING:POLICY] Pause on device change: ${enabled ? "ENABLED" : "DISABLED"}',
    );
    return _setOptimisticScalar(
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
  }

  /// Notifies root controller listeners only when the controller has not been
  /// disposed.
  @override
  void notifyListeners() {
    if (!_isDisposed) {
      super.notifyListeners();
    }
  }

  /// Cancels stream subscriptions, disposes all scoped domain notifiers, and
  /// releases the underlying [engine].
  @override
  void dispose() {
    MapLogger.info('[ENGINE:DISPOSE] Disposing AudioEngineController.');
    _isDisposed = true;
    _lastRecordingResult = null;
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
