part of 'miniaudio_player.dart';

/// Represents the high-level playback and lifecycle states of [MiniaudioPlayer].
enum PlaybackState {
  /// The player is stopped, rewound to start, or has no active media.
  stopped,

  /// The player is actively preparing, resolving, probing, or loading an audio source.
  opening,

  /// Audio frames are actively rendering through the output audio device.
  playing,

  /// Playback is paused at the current position.
  paused,

  /// Playback reached the end of the track.
  completed,

  /// Playback is stalled waiting for network data or buffer replenishment.
  buffering,

  /// An unrecoverable decoding, I/O, or native engine error occurred.
  error;

  /// Whether the playback state is [PlaybackState.stopped].
  bool get isStopped => this == PlaybackState.stopped;

  /// Whether the playback state is [PlaybackState.opening].
  bool get isOpening => this == PlaybackState.opening;

  /// Whether the playback state is [PlaybackState.playing].
  bool get isPlaying => this == PlaybackState.playing;

  /// Whether the playback state is [PlaybackState.paused].
  bool get isPaused => this == PlaybackState.paused;

  /// Whether the playback state is [PlaybackState.completed].
  bool get isCompleted => this == PlaybackState.completed;

  /// Whether the playback state is [PlaybackState.buffering].
  bool get isBuffering => this == PlaybackState.buffering;

  /// Whether the playback state is [PlaybackState.error].
  bool get isError => this == PlaybackState.error;
}

/// Explicit finite state machine (FSM) phases for queue and crossfade lifecycle.
enum EnginePhase {
  /// The engine is idle without an active stream.
  idle,

  /// An audio track is actively being loaded and probed.
  loading,

  /// Audio frames are actively rendering through the output device.
  playing,

  /// Playback is paused at the current position.
  paused,

  /// An automatic crossfade between consecutive tracks is currently transitioning.
  autoCrossfading,

  /// A manual user-initiated crossfade between tracks is currently transitioning.
  manualCrossfading,

  /// Playback of the active queue or track has completed.
  completed,

  /// An unrecoverable engine or decoding error occurred.
  error,

  /// The player and its native resources have been disposed.
  disposed,
}

/// Synchronous, lock-free $O(1)$ stream snapshot of the player, queue, effects, and DSP states.
///
/// In strict accordance with the stream-driven domain architecture, this state does NOT query
/// Rust synchronously. It holds the latest snapshot delivered across the native event stream.
class PlayerState<T> {
  final MiniaudioPlayer<T> _player;

  /// Creates a [PlayerState] snapshot container for [_player].
  PlayerState(this._player);

  /// The owning [MiniaudioPlayer] instance.
  MiniaudioPlayer<T> get player => _player;

  Duration _position = Duration.zero;

  /// The current playback elapsed position within the active track.
  Duration get position => _position;

  Duration? _duration;

  /// Total timeline duration of the currently active audio track.
  ///
  /// This value is nullable (`Duration?`) by design:
  /// - It is `null` when no track is loaded, or when the current audio source
  ///   is a live broadcast, infinite/unbounded stream, internet radio, or HLS stream
  ///   where the duration is undefined or continuous.
  /// - It is a non-null [Duration] when playing finite audio files or finite network
  ///   streams with a known end, including very short audio clips (e.g. 15ms-100ms sound effects).
  Duration? get duration => _duration;

  PlaybackState _playbackState = PlaybackState.stopped;

  /// The high-level playback state of the player.
  PlaybackState get playbackState => _playbackState;

  EnginePhase _phase = EnginePhase.idle;

  /// The explicit finite state machine phase for queue and crossfade lifecycle.
  EnginePhase get phase => _phase;

  bool _isPlaying = false;

  /// Whether the audio player is actively rendering frames.
  bool get isPlaying => _isPlaying;

  bool _isBuffering = false;

  /// Whether playback is currently stalled waiting for audio buffer replenishment.
  bool get isBuffering => _isBuffering;

  bool _isCompleted = false;

  /// Whether playback of the current track or queue has finished.
  bool get isCompleted => _isCompleted;

  bool _isOpening = false;

  /// Whether an audio track is currently opening or probing.
  bool get isOpening => _isOpening;

  bool _isPaused = false;

  /// Whether playback is currently paused.
  bool get isPaused => _isPaused;

  Buffer _buffer = const Buffer();

  /// The continuous prefetch buffer range and stall status.
  Buffer get buffer => _buffer;

  Uint8List? _metaBytes;

  /// Raw metadata bytes extracted by the native audio engine (e.g. ID3, Vorbis, ICY stream metadata).
  ///
  /// `metaBytes` is only populated when [metaBytesEnabled] is `true`.
  /// If [metaBytesEnabled] is `false`, this is always `null` to conserve bandwidth and prevent
  /// event bus overhead.
  Uint8List? get metaBytes => _metaBytes;

  bool _metaBytesEnabled = false;

  /// Whether the native engine is actively dispatching raw metadata bytes.
  ///
  /// Defaults to `false`. Can be toggled using `player.action.setMetaBytesEnabled(bool)`.
  bool get metaBytesEnabled => _metaBytesEnabled;

  double _volume = 1.0;

  /// The global master playback volume (`>= 0.0`, where `1.0` is unity gain).
  double get volume => _volume;

  double _rate = 1.0;

  /// The playback speed rate multiplier (`> 0.0`, where `1.0` is normal speed).
  double get rate => _rate;

  double _pitch = 1.0;

  /// The playback pitch shift multiplier (`> 0.0`, where `1.0` is normal pitch).
  double get pitch => _pitch;

  double _balance = 0.0;

  /// The stereo balance panning (`-1.0` full left to `1.0` full right).
  double get balance => _balance;

  bool _mono = false;

  /// Whether stereo channels are downmixed to monophonic audio.
  bool get mono => _mono;

  int _bufferSize = 1024;

  /// The audio buffer size in frames.
  int get bufferSize => _bufferSize;

  int _audioBitrate = 0;

  /// The average audio stream bitrate in bits per second.
  int get audioBitrate => _audioBitrate;

  // ignore: prefer_final_fields
  int _sampleRate = 44100;

  /// The native output audio sample rate in Hz.
  int get sampleRate => _sampleRate;

  // ignore: prefer_final_fields
  int _channels = 2;

  /// The number of audio output channels.
  int get channels => _channels;

  Equalizer _equalizer = Equalizer.off;

  /// The currently applied 10-band equalizer settings.
  Equalizer get equalizer => _equalizer;

  List<AudioDevice> _globalOutputDevices = const [AudioDevice.auto];

  /// Global system-wide audio output hardware endpoints (speakers, headphones, HDMI, Bluetooth)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, NOT the player's active outputs.
  List<AudioDevice> get globalOutputDevices => _globalOutputDevices;

  List<AudioDevice> _globalInputDevices = const [
    AudioDevice(id: 'auto', name: 'DEFAULT MICROPHONE', isAuto: true)
  ];

  /// Global system-wide audio input hardware endpoints (microphones, line-in interfaces)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, NOT the player's active inputs.
  List<AudioDevice> get globalInputDevices => _globalInputDevices;

  bool _skipSilence = false;

  /// Whether silence skipping is actively enabled.
  bool get skipSilence => _skipSilence;

  SilenceSkipMode _silenceSkipMode = SilenceSkipMode.disabled;

  /// The current silence detection and skipping mode.
  SilenceSkipMode get silenceSkipMode => _silenceSkipMode;

  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();

  /// The active silence skip configuration.
  SilenceSkipConfig get silenceConfig => _silenceConfig;

  Duration _silenceSavedDuration = Duration.zero;

  /// The cumulative playback time saved by skipping silent regions.
  Duration get silenceSavedDuration => _silenceSavedDuration;

  VisualizerData _visualizer = VisualizerData.empty();

  /// The real-time FFT spectrum and peak amplitude metrics.
  VisualizerData get visualizer => _visualizer;

  bool _visualizerEnabled = false;

  /// Whether real-time 10-band FFT spectrum visualizer calculation is enabled.
  ///
  /// Defaults to `false`. Can be activated via `player.action.setVisualizerEnabled(true)`.
  bool get visualizerEnabled => _visualizerEnabled;

  double _preamp = 0.0;

  /// The master pre-amplification gain in decibels.
  double get preamp => _preamp;

  ReplayGainConfig _replayGain = const ReplayGainConfig(gainDb: 0.0);

  /// The active ReplayGain track normalization settings.
  ReplayGainConfig get replayGain => _replayGain;

  double _defaultReplayGain = 0.0;

  /// The default fallback ReplayGain adjustment in dB.
  double get defaultReplayGain => _defaultReplayGain;

  ReplayGainMode _replayGainMode = ReplayGainMode.track;

  /// The current ReplayGain operating mode.
  ReplayGainMode get replayGainMode => _replayGainMode;

  /// Whether automatic volume normalization is enabled.
  bool get volumeNormalization => _replayGainMode != ReplayGainMode.disabled;

  Crossfeed _crossfeed = Crossfeed.off;

  /// The active Bauer stereophonic-to-binaural crossfeed configuration.
  Crossfeed get crossfeed => _crossfeed;

  bool _spatializerEnabled = false;

  /// Whether stereo widening spatialization is enabled.
  bool get spatializerEnabled => _spatializerEnabled;

  double _spatializerWidth = 1.0;

  /// The stereo widening factor (`0.0` to `2.0`).
  double get spatializerWidth => _spatializerWidth;

  Reverb _reverb = Reverb.off;

  /// The currently applied studio algorithmic reverb configuration.
  Reverb get reverb => _reverb;

  bool _limiterEnabled = true;

  /// Whether the master true-peak brickwall limiter is active.
  bool get limiterEnabled => _limiterEnabled;

  bool _pauseOnDeviceChange = false;

  /// Whether playback pauses when the output hardware device changes.
  bool get pauseOnDeviceChange => _pauseOnDeviceChange;

  List<AudioSource<T>> _queue = const [];

  /// The list of audio sources currently loaded in the playlist queue.
  List<AudioSource<T>> get queue => _queue;

  int? _currentIndex;

  /// The zero-based index of the currently active track in [queue], or `null`
  /// when no queue is loaded or before `play(...)` is invoked for the first time.
  int? get currentIndex => _currentIndex;

  LoopMode _loopMode = LoopMode.off;

  /// The playlist repeat and looping policy.
  LoopMode get loopMode => _loopMode;

  bool _isShuffled = false;

  /// Whether playlist shuffle mode is active.
  bool get isShuffled => _isShuffled;

  InfiniteMixConfig _infiniteMix = InfiniteMixConfig.off;

  /// The active Infinite Mix dynamic queue replenishment configuration.
  InfiniteMixConfig get infiniteMix => _infiniteMix;

  /// Whether Infinite Mix dynamic queue replenishment is enabled.
  bool get infiniteMixEnabled => _infiniteMix.enabled;

  bool _isCrossfading = false;

  /// Whether an automatic or manual crossfade transition is currently in progress.
  bool get isCrossfading => _isCrossfading;

  CrossfadeConfig _crossfadeConfig = const CrossfadeConfig();

  /// The current crossfade duration and curve configuration.
  CrossfadeConfig get crossfadeConfig => _crossfadeConfig;

  int _activeVoicesCount = 0;

  /// The number of polyphonic sound effect voices currently rendering.
  int get activeVoicesCount => _activeVoicesCount;

  int _allocatedRamBytes = 0;

  /// The total memory in bytes currently consumed by decoded sound effects in RAM.
  int get allocatedRamBytes => _allocatedRamBytes;

  int? _maxRamBytes = 50 * 1024 * 1024;

  /// The maximum memory budget in bytes allocated for RAM sound effects,
  /// or `null` if unlimited.
  int? get maxRamBytes => _maxRamBytes;

  List<String> _loadedEffectIds = const [];

  /// The list of string identifiers for effects currently decoded in RAM.
  List<String> get loadedEffectIds => _loadedEffectIds;

  Set<AudioOutput> _outputs = {const AudioOutput()};

  /// Set of active output destinations configured on this player instance
  /// (e.g. default system audio output, specific hardware device, headphone CUE).
  ///
  /// Defaults to a Set containing the default system output: `{const AudioOutput()}`.
  Set<AudioOutput> get outputs => _outputs;

  Set<AudioInput> _inputs = const {};

  /// Set of active audio input sources currently routing audio into this player instance
  /// (e.g. microphones, line-in).
  ///
  /// Defaults to an empty Set `{}`.
  Set<AudioInput> get inputs => _inputs;

  bool _isRecording = false;

  /// Whether live audio recording to a file sink is actively running.
  bool get isRecording => _isRecording;

  AudioOutputSource? _recordingSource;

  /// The audio signal source captured by the active recording session.
  AudioOutputSource? get recordingSource => _recordingSource;

  Duration _recordedDuration = Duration.zero;

  /// The elapsed duration of the active live recording.
  Duration get recordedDuration => _recordedDuration;

  bool _isMicrophoneEnabled = false;

  /// Whether hardware microphone capture is active.
  bool get isMicrophoneEnabled => _isMicrophoneEnabled;

  double _micVolume = 1.0;

  /// The input capture gain of the microphone (`>= 0.0`).
  double get micVolume => _micVolume;

  bool _isDuckingActive = false;

  /// Whether music auto-ducking is currently active due to detected speech.
  bool get isDuckingActive => _isDuckingActive;

  bool _isDirectMonitoringEnabled = false;

  /// Whether low-latency direct microphone pass-through monitoring is enabled.
  bool get isDirectMonitoringEnabled => _isDirectMonitoringEnabled;

  double _micRmsLevel = -100.0;

  /// The instantaneous microphone root-mean-square (RMS) energy level in dBFS.
  double get micRmsLevel => _micRmsLevel;

  /// Whether there is a subsequent track available in the playlist.
  bool get hasNext => _currentIndex != null && _currentIndex! < _queue.length - 1;

  /// Whether there is a preceding track available in the playlist.
  bool get hasPrevious => _currentIndex != null && _currentIndex! > 0;

  AudioSource<T>? _currentItem;

  /// The [AudioSource] currently loaded at [currentIndex], or `null` if no track is active.
  AudioSource<T>? get currentItem => _currentItem;

  /// The optional caller-supplied domain object attached to the current track.
  T? get currentData => _currentItem?.data;
}
