part of 'miniaudio_player.dart';

/// Represents the real transport states of [MiniaudioPlayer].
enum PlaybackState {
  /// The player is stopped, rewound to start, or has reached queue end without repeat.
  stopped,

  /// Audio playback is authorized and actively rendering frames unless temporarily buffering.
  playing,

  /// Audio playback is paused at the current position.
  paused;

  /// Whether the playback state is [PlaybackState.stopped].
  bool get isStopped => this == PlaybackState.stopped;

  /// Whether the playback state is [PlaybackState.playing].
  bool get isPlaying => this == PlaybackState.playing;

  /// Whether the playback state is [PlaybackState.paused].
  bool get isPaused => this == PlaybackState.paused;
}

/// Synchronous, lock-free O(1) stream snapshot of the player, queue, effects, and DSP states.
///
/// In strict accordance with the stream-driven domain architecture, this state does not query
/// Rust synchronously. It holds the latest snapshot delivered across the native event stream.
class PlayerState<T> {
  /// Backing owning player instance.
  final MiniaudioPlayer<T> _player;

  /// Creates a [PlayerState] snapshot container for [_player].
  PlayerState(this._player);

  /// The owning [MiniaudioPlayer] instance.
  MiniaudioPlayer<T> get player => _player;

  /// Backing field for [position].
  Duration _position = Duration.zero;

  /// The current playback elapsed position within the active track.
  Duration get position => _position;

  /// Backing field for [duration].
  Duration? _duration;

  /// Total timeline duration of the currently active audio track, or `null` if unknown (e.g. livestream).
  Duration? get duration => _duration;

  /// Backing field for [playbackState].
  PlaybackState _playbackState = PlaybackState.stopped;

  /// The high-level playback state of the player.
  PlaybackState get playbackState => _playbackState;

  /// Backing field for [isPlaying].
  bool _isPlaying = false;

  /// Whether the audio player is authorized and actively rendering frames.
  bool get isPlaying => _isPlaying;

  /// Backing field for [isBuffering].
  bool _isBuffering = false;

  /// Whether playback is currently stalled waiting for audio buffer replenishment.
  bool get isBuffering => _isBuffering;

  /// Whether playback is currently paused.
  bool get isPaused => _playbackState == PlaybackState.paused;

  /// Backing field for [buffer].
  Buffer _buffer = const Buffer();

  /// The continuous prefetch buffer range and stall status.
  Buffer get buffer => _buffer;

  /// Backing field for [metadataEnabled].
  bool _metadataEnabled = false;

  /// Whether the native engine is actively dispatching metadata.
  ///
  /// Defaults to `false`. Can be toggled using [PlayerAction.setMetadataEnabled].
  bool get metadataEnabled => _metadataEnabled;

  /// Backing field for [metadata].
  AudioMetadata? _metadata;

  /// Encapsulated metadata of the active track, or `null` if disabled or not yet received.
  AudioMetadata? get metadata => _metadata;

  /// Backing field for [audioInfo].
  AudioInfo? _audioInfo;

  /// Technical audio characteristics of the active track (duration, sample rate, channels, bitrate, format),
  /// or `null` if uninitialized.
  AudioInfo? get audioInfo => _audioInfo;

  /// Backing field for [volume].
  double _volume = 1.0;

  /// The global master playback volume (`>= 0.0`, where `1.0` is unity gain).
  double get volume => _volume;

  /// Backing field for [rate].
  double _rate = 1.0;

  /// The playback speed rate multiplier (`> 0.0`, where `1.0` is normal speed).
  double get rate => _rate;

  /// Backing field for [pitch].
  double _pitch = 1.0;

  /// The playback pitch shift multiplier (`> 0.0`, where `1.0` is normal pitch).
  double get pitch => _pitch;

  /// Backing field for [balance].
  double _balance = 0.0;

  /// The stereo balance panning (`-1.0` full left to `1.0` full right).
  double get balance => _balance;

  /// Backing field for [mono].
  bool _mono = false;

  /// Whether stereo channels are downmixed to monophonic audio.
  bool get mono => _mono;

  /// Backing field for [bufferSize].
  int _bufferSize = 1024;

  /// The audio buffer size in frames.
  int get bufferSize => _bufferSize;

  /// Backing field for [equalizer].
  Equalizer _equalizer = Equalizer.off;

  /// The currently applied 10-band equalizer settings.
  Equalizer get equalizer => _equalizer;

  /// Backing field for [globalOutputDevices].
  List<AudioDevice> _globalOutputDevices = const [];

  /// Global system-wide audio output hardware endpoints (speakers, headphones, HDMI, Bluetooth)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, not the player's active outputs.
  List<AudioDevice> get globalOutputDevices => _globalOutputDevices;

  /// Backing field for [globalInputDevices].
  List<AudioDevice> _globalInputDevices = const [];

  /// Global system-wide audio input hardware endpoints (microphones, line-in interfaces)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, not the player's active inputs.
  List<AudioDevice> get globalInputDevices => _globalInputDevices;

  /// Backing field for [skipSilence].
  bool _skipSilence = false;

  /// Whether silence skipping is actively enabled.
  bool get skipSilence => _skipSilence;

  /// Backing field for [silenceSkipMode].
  SilenceSkipMode _silenceSkipMode = SilenceSkipMode.disabled;

  /// The current silence detection and skipping mode.
  SilenceSkipMode get silenceSkipMode => _silenceSkipMode;

  /// Backing field for [silenceConfig].
  SilenceSkipConfig _silenceConfig = const SilenceSkipConfig();

  /// The active silence skip configuration.
  SilenceSkipConfig get silenceConfig => _silenceConfig;

  /// Backing field for [silenceSavedDuration].
  Duration _silenceSavedDuration = Duration.zero;

  /// The cumulative playback time saved by skipping silent regions.
  Duration get silenceSavedDuration => _silenceSavedDuration;

  /// Backing field for [visualizer].
  VisualizerData _visualizer = VisualizerData.empty();

  /// The real-time FFT spectrum and peak amplitude metrics.
  VisualizerData get visualizer => _visualizer;

  /// Backing field for [visualizerEnabled].
  bool _visualizerEnabled = false;

  /// Whether real-time 10-band FFT spectrum visualizer calculation is enabled.
  ///
  /// Defaults to `false`. Can be activated via [PlayerAction.setVisualizerEnabled].
  bool get visualizerEnabled => _visualizerEnabled;

  /// Backing field for [visualizerSource].
  AudioOutputSource _visualizerSource = AudioOutputSource.all;

  /// The audio bus stream currently feeding the real-time FFT spectrum visualizer.
  AudioOutputSource get visualizerSource => _visualizerSource;

  /// Backing field for [preamp].
  double _preamp = 0.0;

  /// The master pre-amplification gain in decibels.
  double get preamp => _preamp;

  /// Backing field for [replayGain].
  ReplayGainConfig _replayGain = const ReplayGainConfig(gainDb: 0.0);

  /// The active ReplayGain track normalization settings.
  ReplayGainConfig get replayGain => _replayGain;

  /// Backing field for [defaultReplayGain].
  double _defaultReplayGain = 0.0;

  /// The default fallback ReplayGain adjustment in dB.
  double get defaultReplayGain => _defaultReplayGain;

  /// Backing field for [replayGainMode].
  ReplayGainMode _replayGainMode = ReplayGainMode.track;

  /// The current ReplayGain operating mode.
  ReplayGainMode get replayGainMode => _replayGainMode;

  /// Whether automatic volume normalization is enabled.
  bool get volumeNormalization => _replayGainMode != ReplayGainMode.disabled;

  /// Backing field for [crossfeed].
  Crossfeed _crossfeed = Crossfeed.off;

  /// The active Bauer stereophonic-to-binaural crossfeed configuration.
  Crossfeed get crossfeed => _crossfeed;

  /// Backing field for [spatializerEnabled].
  bool _spatializerEnabled = false;

  /// Whether stereo widening spatialization is enabled.
  bool get spatializerEnabled => _spatializerEnabled;

  /// Backing field for [spatializerWidth].
  double _spatializerWidth = 1.0;

  /// The stereo widening factor (`0.0` to `2.0`).
  double get spatializerWidth => _spatializerWidth;

  /// Backing field for [reverb].
  Reverb _reverb = Reverb.off;

  /// The currently applied studio algorithmic reverb configuration.
  Reverb get reverb => _reverb;

  /// Backing field for [limiterEnabled].
  bool _limiterEnabled = true;

  /// Whether the master true-peak brickwall limiter is active.
  bool get limiterEnabled => _limiterEnabled;

  /// Backing field for [pauseOnDeviceChange].
  bool _pauseOnDeviceChange = false;

  /// Whether playback pauses when the output hardware device changes.
  bool get pauseOnDeviceChange => _pauseOnDeviceChange;

  /// Backing field for [queue].
  List<AudioSource<T>> _queue = const [];

  /// The list of audio sources currently loaded in the playlist queue.
  List<AudioSource<T>> get queue => _queue;

  /// Backing field for [currentIndex].
  int? _currentIndex;

  /// The zero-based index of the currently active track in [queue], or `null`
  /// when no queue is loaded or before `play(...)` is invoked for the first time.
  int? get currentIndex => _currentIndex;

  /// Backing field for [loopMode].
  LoopMode _loopMode = LoopMode.off;

  /// The playlist repeat and looping policy.
  LoopMode get loopMode => _loopMode;

  /// Backing field for [isShuffled].
  bool _isShuffled = false;

  /// Whether playlist shuffle mode is active.
  bool get isShuffled => _isShuffled;

  /// Backing field for [infiniteMix].
  InfiniteMixConfig _infiniteMix = InfiniteMixConfig.off;

  /// The active Infinite Mix dynamic queue replenishment configuration.
  InfiniteMixConfig get infiniteMix => _infiniteMix;

  /// Whether Infinite Mix dynamic queue replenishment is enabled.
  bool get infiniteMixEnabled => _infiniteMix.enabled;

  /// Backing field for [isCrossfading].
  bool _isCrossfading = false;

  /// Whether an automatic or manual crossfade transition is currently in progress.
  bool get isCrossfading => _isCrossfading;

  /// Backing field for [crossfadeConfig].
  CrossfadeConfig _crossfadeConfig = const CrossfadeConfig();

  /// The current crossfade duration and curve configuration.
  CrossfadeConfig get crossfadeConfig => _crossfadeConfig;

  /// Backing field for [activeVoicesCount].
  int _activeVoicesCount = 0;

  /// The number of polyphonic sound effect voices currently rendering.
  int get activeVoicesCount => _activeVoicesCount;

  /// Backing field for [allocatedRamBytes].
  int _allocatedRamBytes = 0;

  /// The total memory in bytes currently consumed by decoded sound effects in RAM.
  int get allocatedRamBytes => _allocatedRamBytes;

  /// Backing field for [maxRamBytes].
  int? _maxRamBytes = 50 * 1024 * 1024;

  /// The maximum memory budget in bytes allocated for RAM sound effects,
  /// or `null` if unlimited.
  int? get maxRamBytes => _maxRamBytes;

  /// Backing field for [loadedEffectIds].
  List<String> _loadedEffectIds = const [];

  /// The list of string identifiers for effects currently decoded in RAM.
  List<String> get loadedEffectIds => _loadedEffectIds;

  /// Backing field for [outputs].
  Set<AudioOutput> _outputs = {const AudioOutput()};

  /// Set of active output destinations configured on this player instance
  /// (e.g. default system audio output, specific hardware device, headphone CUE).
  ///
  /// Defaults to a Set containing the default system output: `{const AudioOutput()}`.
  ///
  /// ### Physical Endpoint Collision Resolution
  /// If this set contains both `'AUTO'` and a specific physical device ID that resolves
  /// to the same underlying OS endpoint, the native Rust audio engine deduplicates the
  /// physical hardware endpoint, prioritizing `'AUTO'` and its configuration so only
  /// one audio stream is rendered to the hardware DAC. This set retains all items as
  /// declared by the user without modification.
  Set<AudioOutput> get outputs => _outputs;

  /// Backing field for [inputs].
  Set<AudioInput> _inputs = const {};

  /// Set of active audio input sources currently routing audio into this player instance
  /// (e.g. microphones, line-in).
  ///
  /// Defaults to an empty Set `{}`.
  ///
  /// ### Physical Endpoint Collision Resolution
  /// If this set contains both `'AUTO'` and a specific physical device ID that resolves
  /// to the same underlying OS capture endpoint, the native Rust audio engine deduplicates
  /// the physical hardware endpoint, prioritizing `'AUTO'` and its configuration. This set
  /// retains all items as declared by the user without modification.
  Set<AudioInput> get inputs => _inputs;

  /// Backing field for [isRecording].
  bool _isRecording = false;

  /// Whether live audio recording to a file sink is actively running.
  bool get isRecording => _isRecording;

  /// Backing field for [recordingSource].
  AudioOutputSource? _recordingSource;

  /// The audio signal source captured by the active recording session.
  AudioOutputSource? get recordingSource => _recordingSource;

  /// Backing field for [recordedDuration].
  Duration _recordedDuration = Duration.zero;

  /// The elapsed duration of the active live recording.
  Duration get recordedDuration => _recordedDuration;

  /// Backing field for [isDuckingActive].
  bool _isDuckingActive = false;

  /// Whether music auto-ducking is currently active due to detected speech.
  bool get isDuckingActive => _isDuckingActive;

  /// Backing field for [micRmsLevel].
  double _micRmsLevel = -100.0;

  /// The instantaneous microphone root-mean-square (RMS) energy level in dBFS.
  double get micRmsLevel => _micRmsLevel;

  /// Whether there is a subsequent track available in the playlist.
  bool get hasNext =>
      _currentIndex != null && _currentIndex! < _queue.length - 1;

  /// Whether there is a preceding track available in the playlist.
  bool get hasPrevious => _currentIndex != null && _currentIndex! > 0;

  /// The [AudioSource] currently loaded at [currentIndex], or `null` if no track is active.
  AudioSource<T>? get currentItem {
    final idx = _currentIndex;
    return (idx != null && idx >= 0 && idx < _queue.length)
        ? _queue[idx]
        : null;
  }

  /// The optional caller-supplied domain object attached to the current track.
  T? get currentData => currentItem?.data;
}
