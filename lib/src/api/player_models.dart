import '../equalizer.dart';
import '../reverb.dart';
import 'audio_source.dart';
import 'crossfade_config.dart';
import 'recording.dart' show DuckingConfig, WavFormat;
import 'spatial.dart';

/// Unique identifier for an active polyphonic RAM voice.
typedef VoiceId = int;

/// Formats supported for real-time audio file recording sinks.
enum AudioFileFormat {
  /// Uncompressed 16-bit signed PCM WAV.
  wav,

  /// MP3 compressed audio stream.
  mp3,

  /// FLAC lossless compressed audio stream.
  flac;

  WavFormat toWavFormat() {
    switch (this) {
      case AudioFileFormat.wav:
      case AudioFileFormat.mp3:
      case AudioFileFormat.flac:
        return WavFormat.pcm16;
    }
  }
}

/// Routing source options for the secondary DJ CUE / headphone output.
enum CueSource {
  /// Incoming / standby track deck.
  standbyTrack(0),

  /// Active currently playing track deck.
  activeTrack(1),

  /// Full composite Master mix.
  masterMix(2);

  final int value;
  const CueSource(this.value);

  static CueSource fromValue(int val) {
    switch (val) {
      case 0:
        return CueSource.standbyTrack;
      case 1:
        return CueSource.activeTrack;
      case 2:
      default:
        return CueSource.masterMix;
    }
  }
}

/// Sealed hierarchy representing audio output destinations in the multi-matrix mixer.
sealed class AudioOutput {
  const AudioOutput();

  /// Default system speaker output.
  const factory AudioOutput.speaker({bool exclusiveMode}) = SpeakerAudioOutput;

  /// Specific hardware output device identified by [deviceId].
  const factory AudioOutput.device(String deviceId, {bool exclusiveMode}) =
      DeviceAudioOutput;

  /// Dedicated headphone CUE pre-listening output device.
  const factory AudioOutput.cue(String deviceId, {CueSource source}) =
      CueAudioOutput;

  /// Real-time live file recording destination.
  const factory AudioOutput.file(String path, {AudioFileFormat format}) =
      FileAudioOutput;
}

/// Default system speaker output configuration.
class SpeakerAudioOutput extends AudioOutput {
  final bool exclusiveMode;
  const SpeakerAudioOutput({this.exclusiveMode = false});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SpeakerAudioOutput && exclusiveMode == other.exclusiveMode;

  @override
  int get hashCode => exclusiveMode.hashCode ^ 1;
}

/// Specific hardware audio output device.
class DeviceAudioOutput extends AudioOutput {
  final String deviceId;
  final bool exclusiveMode;
  const DeviceAudioOutput(this.deviceId, {this.exclusiveMode = false});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceAudioOutput &&
          deviceId == other.deviceId &&
          exclusiveMode == other.exclusiveMode;

  @override
  int get hashCode => deviceId.hashCode ^ exclusiveMode.hashCode ^ 2;
}

/// Dedicated CUE pre-listening headphone output.
class CueAudioOutput extends AudioOutput {
  final String deviceId;
  final CueSource source;
  const CueAudioOutput(this.deviceId, {this.source = CueSource.standbyTrack});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CueAudioOutput &&
          deviceId == other.deviceId &&
          source == other.source;

  @override
  int get hashCode => deviceId.hashCode ^ source.hashCode ^ 3;
}

/// Live audio file recording output sink.
class FileAudioOutput extends AudioOutput {
  final String path;
  final AudioFileFormat format;
  const FileAudioOutput(this.path, {this.format = AudioFileFormat.wav});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FileAudioOutput && path == other.path && format == other.format;

  @override
  int get hashCode => path.hashCode ^ format.hashCode ^ 4;
}

/// Sealed hierarchy representing audio input sources.
sealed class AudioInput {
  const AudioInput();

  /// Hardware microphone capture input.
  const factory AudioInput.microphone({
    String? deviceId,
    double volume,
    DuckingConfig? ducking,
    bool monitorDirect,
    double monitorVolume,
  }) = MicrophoneAudioInput;
}

/// Hardware microphone input node configuration.
class MicrophoneAudioInput extends AudioInput {
  final String? deviceId;
  final double volume;
  final DuckingConfig? ducking;
  final bool monitorDirect;
  final double monitorVolume;

  const MicrophoneAudioInput({
    this.deviceId,
    this.volume = 1.0,
    this.ducking,
    this.monitorDirect = false,
    this.monitorVolume = 1.0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MicrophoneAudioInput &&
          deviceId == other.deviceId &&
          volume == other.volume &&
          ducking == other.ducking &&
          monitorDirect == other.monitorDirect &&
          monitorVolume == other.monitorVolume;

  @override
  int get hashCode =>
      deviceId.hashCode ^
      volume.hashCode ^
      ducking.hashCode ^
      monitorDirect.hashCode ^
      monitorVolume.hashCode;
}

/// Descriptor of an audio effect preloaded in memory for polyphonic playback.
class AudioEffect {
  final String id;
  final AudioSource source;
  final int maxPolyphony;
  final bool pinned;

  const AudioEffect({
    required this.id,
    required this.source,
    this.maxPolyphony = 16,
    this.pinned = false,
  });
}

/// Routing policy for audio effects through the DSP pipeline.
enum DspRouting {
  /// Inherits master track DSP settings with local overrides (Default).
  inherit(0),

  /// Isolates voice from music DSP chain, processing only its own configuration.
  isolate(1),

  /// Bypasses all DSP (dry output directly to mixer).
  bypass(2);

  final int value;
  const DspRouting(this.value);

  static DspRouting fromValue(int val) {
    switch (val) {
      case 0:
        return DspRouting.inherit;
      case 1:
        return DspRouting.isolate;
      case 2:
      default:
        return DspRouting.bypass;
    }
  }
}

/// Polyphonic voice stealing policy when voice budget is saturated.
enum VoiceStealingPolicy {
  /// Steal the voice with the lowest priority value.
  lowestPriority(0),

  /// Steal the oldest active playing voice.
  oldest(1),

  /// Steal the quietest voice currently playing.
  quietest(2),

  /// Steal the voice located furthest away from listener.
  farthest(3);

  final int value;
  const VoiceStealingPolicy(this.value);

  static VoiceStealingPolicy fromValue(int val) {
    switch (val) {
      case 0:
        return VoiceStealingPolicy.lowestPriority;
      case 1:
        return VoiceStealingPolicy.oldest;
      case 2:
        return VoiceStealingPolicy.quietest;
      case 3:
      default:
        return VoiceStealingPolicy.farthest;
    }
  }
}

/// Configuration applied when triggering a polyphonic audio effect voice.
class EffectConfig {
  final double volume;
  final double balance;
  final double pitch;
  final double rate;
  final bool looping;
  final int priority;
  final double pitchJitter;
  final double volumeJitter;
  final SpatialEmitter? spatial;
  final Equalizer? equalizer;
  final Reverb? reverb;
  final VoiceStealingPolicy stealingPolicy;
  final int maxPolyphony;
  final DspRouting dspRouting;
  final bool pinned;

  const EffectConfig({
    this.volume = 1.0,
    this.balance = 0.0,
    this.pitch = 1.0,
    this.rate = 1.0,
    this.looping = false,
    this.priority = 128,
    this.pitchJitter = 0.0,
    this.volumeJitter = 0.0,
    this.spatial,
    this.equalizer,
    this.reverb,
    this.stealingPolicy = VoiceStealingPolicy.oldest,
    this.maxPolyphony = 16,
    this.dspRouting = DspRouting.inherit,
    this.pinned = false,
  });

  EffectConfig copyWith({
    double? volume,
    double? balance,
    double? pitch,
    double? rate,
    bool? looping,
    int? priority,
    double? pitchJitter,
    double? volumeJitter,
    SpatialEmitter? spatial,
    Equalizer? equalizer,
    Reverb? reverb,
    VoiceStealingPolicy? stealingPolicy,
    int? maxPolyphony,
    DspRouting? dspRouting,
    bool? pinned,
  }) {
    return EffectConfig(
      volume: volume ?? this.volume,
      balance: balance ?? this.balance,
      pitch: pitch ?? this.pitch,
      rate: rate ?? this.rate,
      looping: looping ?? this.looping,
      priority: priority ?? this.priority,
      pitchJitter: pitchJitter ?? this.pitchJitter,
      volumeJitter: volumeJitter ?? this.volumeJitter,
      spatial: spatial ?? this.spatial,
      equalizer: equalizer ?? this.equalizer,
      reverb: reverb ?? this.reverb,
      stealingPolicy: stealingPolicy ?? this.stealingPolicy,
      maxPolyphony: maxPolyphony ?? this.maxPolyphony,
      dspRouting: dspRouting ?? this.dspRouting,
      pinned: pinned ?? this.pinned,
    );
  }
}

/// Configuration parameters governing [MiniaudioPlayer] behavior.
class PlayerConfig {
  final int sampleRate;
  final int channels;
  final int bufferSizeFrames;
  final int maxVoices;
  final int maxRamBytes;
  final VoiceStealingPolicy voiceStealingPolicy;
  final bool autoPlay;
  final bool pauseOnDeviceChange;
  final Duration bufferLocalDuration;
  final Duration bufferNetworkDuration;
  final CrossfadeConfig? crossfade;
  final bool enableSpatialAudio;

  const PlayerConfig({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bufferSizeFrames = 1024,
    this.maxVoices = 64,
    this.maxRamBytes = 64 * 1024 * 1024, // 64 MB
    this.voiceStealingPolicy = VoiceStealingPolicy.lowestPriority,
    this.autoPlay = false,
    this.pauseOnDeviceChange = false,
    this.bufferLocalDuration = const Duration(seconds: 30),
    this.bufferNetworkDuration = const Duration(seconds: 30),
    this.crossfade,
    this.enableSpatialAudio = true,
  });
}

/// Immutable record summarizing the metrics of a completed audio recording.
class RecordingResult {
  final String path;
  final Duration duration;
  final int bytesWritten;
  final int sampleCount;

  const RecordingResult({
    required this.path,
    required this.duration,
    required this.bytesWritten,
    required this.sampleCount,
  });
}
