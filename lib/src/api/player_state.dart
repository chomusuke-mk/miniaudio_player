import 'dart:typed_data';

import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffer.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'player_models.dart';
import 'silence_skip_config.dart';
import 'visualizer_data.dart';

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

  /// Convenience boolean predicates
  bool get isStopped => this == PlaybackState.stopped;
  bool get isOpening => this == PlaybackState.opening;
  bool get isPlaying => this == PlaybackState.playing;
  bool get isPaused => this == PlaybackState.paused;
  bool get isCompleted => this == PlaybackState.completed;
  bool get isBuffering => this == PlaybackState.buffering;
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

  /// The current playback elapsed position within the active track.
  Duration position = Duration.zero;

  /// Total timeline duration of the currently active audio track.
  ///
  /// This value is nullable (`Duration?`) by design:
  /// - It is `null` when no track is loaded, or when the current audio source
  ///   is a live broadcast, infinite/unbounded stream, internet radio, or HLS stream
  ///   where the duration is undefined or continuous.
  /// - It is a non-null [Duration] when playing finite audio files or finite network
  ///   streams with a known end, including very short audio clips (e.g. 15ms-100ms sound effects).
  Duration? duration;

  /// The high-level playback state of the player.
  PlaybackState playbackState = PlaybackState.stopped;

  /// The explicit finite state machine phase for queue and crossfade lifecycle.
  EnginePhase phase = EnginePhase.idle;

  /// Whether the audio player is actively rendering frames.
  bool isPlaying = false;

  /// Whether playback is currently stalled waiting for audio buffer replenishment.
  bool isBuffering = false;

  /// Whether playback of the current track or queue has finished.
  bool isCompleted = false;

  /// Whether an audio track is currently opening or probing.
  bool isOpening = false;

  /// Whether playback is currently paused.
  bool isPaused = false;

  /// Whether the audio player is actively rendering frames (convenience alias for [isPlaying]).
  bool get playing => isPlaying;

  /// Whether playback is currently stalled (convenience alias for [isBuffering]).
  bool get buffering => isBuffering;

  /// Whether playback has finished (convenience alias for [isCompleted]).
  bool get completed => isCompleted;

  /// Whether an audio track is opening (convenience alias for [isOpening]).
  bool get opening => isOpening;

  /// Whether playback is currently stopped.
  bool get isStopped => playbackState == PlaybackState.stopped;

  /// Whether the player is currently in an error state.
  bool get isError => playbackState == PlaybackState.error;

  /// The continuous prefetch buffer range and stall status.
  Buffer buffer = const Buffer();

  /// Raw metadata bytes extracted by the native audio engine (e.g. ID3, Vorbis, ICY stream metadata).
  ///
  /// `metaBytes` is only populated when [metaBytesEnabled] is `true`.
  /// If [metaBytesEnabled] is `false`, this is always `null` to conserve bandwidth and prevent
  /// event bus overhead.
  Uint8List? metaBytes;

  /// Whether the native engine is actively dispatching raw metadata bytes.
  ///
  /// Defaults to `false`. Can be toggled using `player.action.setMetaBytesEnabled(bool)`.
  bool metaBytesEnabled = false;

  /// The global master playback volume (`0.0` to `2.0`).
  double volume = 1.0;

  /// The playback speed rate multiplier (`0.5` to `2.0`).
  double rate = 1.0;

  /// The playback pitch shift multiplier (`0.5` to `2.0`).
  double pitch = 1.0;

  /// The stereo balance panning (`-1.0` full left to `1.0` full right).
  double balance = 0.0;

  /// Whether stereo channels are downmixed to monophonic audio.
  bool mono = false;

  /// Whether stereo channels are downmixed to monophonic audio (convenience alias for [mono]).
  bool get isMono => mono;

  /// The audio buffer size in frames.
  int bufferSize = 1024;

  /// The audio buffer size in frames (convenience alias for [bufferSize]).
  int get bufferSizeFrames => bufferSize;

  /// The average audio stream bitrate in bits per second.
  int audioBitrate = 0;

  /// The average audio stream bitrate in bits per second (convenience alias for [audioBitrate]).
  int get bitrate => audioBitrate;

  /// The native output audio sample rate in Hz.
  int sampleRate = 44100;

  /// The number of audio output channels.
  int channels = 2;

  /// The currently applied 10-band equalizer settings.
  Equalizer equalizer = Equalizer.flat;

  /// The primary audio output device configured on the player.
  AudioDevice audioDevice = AudioDevice.auto;

  /// Global system-wide audio output hardware endpoints (speakers, headphones, HDMI, Bluetooth)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, NOT the player's active outputs.
  List<AudioDevice> globalOutputDevices = const [AudioDevice.auto];

  /// Global system-wide audio input hardware endpoints (microphones, line-in interfaces)
  /// currently connected and detected by the operating system.
  ///
  /// NOTE: This lists external OS hardware devices, NOT the player's active inputs.
  List<AudioDevice> globalInputDevices = const [
    AudioDevice(id: 'auto', name: 'DEFAULT MICROPHONE', isAuto: true)
  ];

  /// The currently selected audio input device.
  AudioDevice? activeInputDevice;

  /// Whether silence skipping is actively enabled.
  bool skipSilence = false;

  /// The current silence detection and skipping mode.
  SilenceSkipMode silenceSkipMode = SilenceSkipMode.disabled;

  /// The active silence skip configuration.
  SilenceSkipConfig silenceConfig = const SilenceSkipConfig();

  /// The cumulative playback time saved by skipping silent regions.
  Duration silenceSavedDuration = Duration.zero;

  /// The real-time FFT spectrum and peak amplitude metrics.
  VisualizerData visualizer = VisualizerData.empty();

  /// Whether real-time 10-band FFT spectrum visualizer calculation is enabled.
  ///
  /// Defaults to `false`. Can be activated via `player.action.setVisualizerEnabled(true)`.
  bool visualizerEnabled = false;

  /// The master pre-amplification gain in decibels.
  double preamp = 0.0;

  /// The master pre-amplification gain in decibels (convenience alias for [preamp]).
  double get preampDb => preamp;

  /// The active ReplayGain track normalization settings.
  ReplayGainConfig replayGain = const ReplayGainConfig();

  /// Whether automatic volume normalization is enabled.
  bool volumeNormalization = true;

  /// The default fallback ReplayGain adjustment in dB.
  double defaultReplayGain = 0.0;

  /// The uniform forced ReplayGain adjustment in dB.
  double forcedReplayGain = 0.0;

  /// The current ReplayGain operating mode.
  ReplayGainMode replayGainMode = ReplayGainMode.track;

  /// The active Bauer stereophonic-to-binaural crossfeed mode.
  CrossfeedMode crossfeed = CrossfeedMode.off;

  /// Whether stereo widening spatialization is enabled.
  bool spatializerEnabled = false;

  /// The stereo widening factor (`0.0` to `2.0`).
  double spatializerWidth = 1.0;

  /// The currently applied studio algorithmic reverb configuration.
  Reverb reverb = Reverb.off;

  /// Whether the master true-peak brickwall limiter is active.
  bool limiterEnabled = true;

  /// Whether the master true-peak brickwall limiter is active (convenience alias for [limiterEnabled]).
  bool get isLimiterEnabled => limiterEnabled;

  /// Whether playback pauses when the output hardware device changes.
  bool pauseOnDeviceChange = false;

  /// The list of audio sources currently loaded in the playlist queue.
  List<AudioSource<T>> queue = const [];

  /// The zero-based index of the currently active track in [queue], or `-1` if empty.
  int currentIndex = -1;

  /// The playlist repeat and looping policy.
  LoopMode loopMode = LoopMode.off;

  /// Whether playlist shuffle mode is active.
  bool isShuffled = false;

  /// Whether playlist shuffle mode is active (convenience alias for [isShuffled]).
  bool get shuffle => isShuffled;

  /// Whether Infinite Mix dynamic queue replenishment is enabled.
  bool get infiniteMixEnabled => _player.infiniteMixEnabled;

  /// Whether an automatic or manual crossfade transition is currently in progress.
  bool isCrossfading = false;

  /// The current crossfade duration and curve configuration.
  CrossfadeConfig crossfadeConfig = const CrossfadeConfig();

  /// The number of polyphonic sound effect voices currently rendering.
  int activeVoicesCount = 0;

  /// The total memory in bytes currently consumed by preloaded sound effects.
  int allocatedRamBytes = 0;

  /// The maximum memory budget in bytes allocated for RAM sound effects.
  int maxRamBytes = 64 * 1024 * 1024;

  /// The list of string identifiers for effects currently preloaded in RAM.
  List<String> loadedEffectIds = const [];

  /// Set of active output destinations configured on this player instance
  /// (e.g. default speaker, specific hardware device, headphone CUE, live file recording).
  ///
  /// Defaults to a Set containing [AudioOutput.speaker()].
  Set<AudioOutput> outputs = {const AudioOutput.speaker()};

  /// Set of active audio input sources currently routing audio into this player instance
  /// (e.g. microphones, line-in).
  ///
  /// Defaults to an empty Set `{}`.
  Set<AudioInput> inputs = const {};

  /// Whether live audio recording to a file sink is actively running.
  bool isRecording = false;

  /// The elapsed duration of the active live recording.
  Duration recordedDuration = Duration.zero;

  /// The headphone volume for the secondary DJ cue output (`0.0` to `2.0`).
  double cueVolume = 1.0;

  /// The source routing for the secondary DJ cue output.
  CueSource cueSource = CueSource.standbyTrack;

  /// Whether hardware microphone capture is active.
  bool isMicrophoneEnabled = false;

  /// The input capture gain of the microphone (`0.0` to `2.0`).
  double micVolume = 1.0;

  /// Whether music auto-ducking is currently active due to detected speech.
  bool isDuckingActive = false;

  /// Whether low-latency direct microphone pass-through monitoring is enabled.
  bool isDirectMonitoringEnabled = false;

  /// The instantaneous microphone root-mean-square (RMS) energy level in dBFS.
  double micRmsLevel = -100.0;

  /// Whether there is a subsequent track available in the playlist.
  bool get hasNext => currentIndex >= 0 && currentIndex < queue.length - 1;

  /// Whether there is a preceding track available in the playlist.
  bool get hasPrevious => currentIndex > 0;

  /// The [AudioSource] currently loaded at [currentIndex], or `null` if empty.
  AudioSource<T>? get currentItem =>
      (currentIndex >= 0 && currentIndex < queue.length) ? queue[currentIndex] : null;

  /// The optional caller-supplied domain object attached to the current track.
  T? get currentData => currentItem?.data;

  /// The byte size of preloaded metadata bytes.
  int get pinnedHeadSize => metaBytes?.length ?? 0;
}
