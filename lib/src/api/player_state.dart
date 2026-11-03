import 'dart:typed_data';

import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'audio_source.dart';
import 'buffered_range.dart';
import 'crossfade_config.dart';
import 'dsp_config.dart';
import 'loop_mode.dart';
import 'miniaudio_player.dart';
import 'player_models.dart';
import 'silence_skip_config.dart';
import 'track_metadata.dart';
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
  idle,
  loading,
  playing,
  paused,
  autoCrossfading,
  manualCrossfading,
  completed,
  error,
  disposed,
}

/// Synchronous, lock-free $O(1)$ stream snapshot of the player, queue, effects, and DSP states.
///
/// In strict accordance with the stream-driven domain architecture, this state does NOT query
/// Rust synchronously. It holds the latest snapshot delivered across the native event stream.
class PlayerState<T> {
  final MiniaudioPlayer<T> _player;

  PlayerState(this._player);

  MiniaudioPlayer<T> get player => _player;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  PlaybackState playbackState = PlaybackState.stopped;
  EnginePhase phase = EnginePhase.idle;

  bool isPlaying = false;
  bool isBuffering = false;
  bool isCompleted = false;
  bool isOpening = false;
  bool isPaused = false;
  bool get playing => isPlaying;
  bool get buffering => isBuffering;
  bool get completed => isCompleted;
  bool get opening => isOpening;
  bool get isStopped => playbackState == PlaybackState.stopped;
  bool get isError => playbackState == PlaybackState.error;

  BufferedRange bufferedRange = const BufferedRange();
  Duration bufferedPosition = Duration.zero;
  double bufferedPercentage = 0.0;
  AudioTrackMetadata? trackMetadata;
  Uint8List? metaBytes;

  double volume = 1.0;
  double rate = 1.0;
  double pitch = 1.0;
  double balance = 0.0;
  bool mono = false;
  bool get isMono => mono;

  int bufferSize = 1024;
  int get bufferSizeFrames => bufferSize;
  int audioBitrate = 0;
  int get bitrate => audioBitrate;
  int sampleRate = 44100;
  int channels = 2;

  Equalizer equalizer = Equalizer.flat;
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
  AudioDevice? activeInputDevice;

  bool skipSilence = false;
  SilenceSkipMode silenceSkipMode = SilenceSkipMode.disabled;
  SilenceSkipConfig silenceConfig = const SilenceSkipConfig();
  Duration silenceSavedDuration = Duration.zero;

  VisualizerData visualizer = VisualizerData.empty();
  bool visualizerEnabled = false;
  bool get isVisualizerEnabled => visualizerEnabled;

  double preamp = 0.0;
  double get preampDb => preamp;
  ReplayGainConfig replayGain = const ReplayGainConfig();
  bool volumeNormalization = true;
  double defaultReplayGain = 0.0;
  double forcedReplayGain = 0.0;
  ReplayGainMode replayGainMode = ReplayGainMode.track;

  CrossfeedMode crossfeed = CrossfeedMode.off;
  bool spatializerEnabled = false;
  double spatializerWidth = 1.0;
  Reverb reverb = Reverb.off;
  bool limiterEnabled = true;
  bool get isLimiterEnabled => limiterEnabled;

  bool pauseOnDeviceChange = false;

  List<AudioSource<T>> queue = const [];
  int currentIndex = -1;
  LoopMode loopMode = LoopMode.off;
  bool isShuffled = false;
  bool get shuffle => isShuffled;
  bool get infiniteMixEnabled => _player.infiniteMixEnabled;
  bool isCrossfading = false;
  CrossfadeConfig crossfadeConfig = const CrossfadeConfig();

  int activeVoicesCount = 0;
  int allocatedRamBytes = 0;
  int maxRamBytes = 64 * 1024 * 1024;
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
  bool isRecording = false;
  Duration recordedDuration = Duration.zero;
  double cueVolume = 1.0;
  CueSource cueSource = CueSource.standbyTrack;

  bool isMicrophoneEnabled = false;
  double micVolume = 1.0;
  bool isDuckingActive = false;
  bool isDirectMonitoringEnabled = false;
  double micRmsLevel = -100.0;

  bool get hasNext => currentIndex >= 0 && currentIndex < queue.length - 1;
  bool get hasPrevious => currentIndex > 0;
  AudioSource<T>? get currentItem =>
      (currentIndex >= 0 && currentIndex < queue.length) ? queue[currentIndex] : null;
  T? get currentData => currentItem?.data;
  int get pinnedHeadSize => metaBytes?.length ?? 0;

  bool get isLiveStream {
    if (trackMetadata != null) return trackMetadata!.isLiveStream;
    final item = currentItem;
    if (item is UriAudioSource) {
      final s = (item as UriAudioSource).sourceString.toLowerCase();
      final isNet = s.startsWith('http://') || s.startsWith('https://');
      if (s.contains('.m3u8')) return true;
      if (isNet && duration == Duration.zero) return true;
    }
    return false;
  }
}
