import '../equalizer.dart';
import '../reverb.dart';
import 'audio_device.dart';
import 'crossfade_config.dart';
import 'miniaudio_player.dart';
import 'recording.dart' show DuckingConfig, WavFormat;
import 'spatial.dart';

/// Formats supported for real-time audio file recording sinks.
enum AudioFileFormat {
  /// Uncompressed 16-bit signed PCM WAV.
  wav,

  /// MP3 compressed audio stream.
  mp3,

  /// FLAC lossless compressed audio stream.
  flac;

  /// Converts this [AudioFileFormat] to its corresponding native [WavFormat].
  WavFormat toWavFormat() {
    switch (this) {
      case AudioFileFormat.wav:
      case AudioFileFormat.mp3:
      case AudioFileFormat.flac:
        return WavFormat.pcm16;
    }
  }
}

/// Audio signal source routed to an output device or live file recording session.
enum AudioOutputSource {
  /// Complete master mix (music + SFX voices + microphone + ducking + master limiter).
  all(0),

  /// Pure music mix from decks with music DSP (EQ, Reverb), excluding SFX and microphone.
  musicMix(1),

  /// Isolated active deck track only.
  activeTrack(2),

  /// Isolated standby deck track only (ideal for DJ pre-listening).
  standbyTrack(3);

  /// Raw native enum value.
  final int value;
  const AudioOutputSource(this.value);

  /// Resolves an [AudioOutputSource] from its raw integer [val].
  static AudioOutputSource fromValue(int val) {
    switch (val) {
      case 1:
        return AudioOutputSource.musicMix;
      case 2:
        return AudioOutputSource.activeTrack;
      case 3:
        return AudioOutputSource.standbyTrack;
      case 0:
      default:
        return AudioOutputSource.all;
    }
  }
}

/// Represents a hardware or virtual audio playback destination.
///
/// When [deviceId] is null, the player routes audio to the operating system's
/// default audio output endpoint (automatic routing).
///
/// [source] determines which audio stream is routed to this endpoint:
/// - [AudioOutputSource.all]: Complete master mix (playback tracks + sound effects + mic).
/// - [AudioOutputSource.musicMix]: Pure music mix from decks, excluding SFX and mic.
/// - [AudioOutputSource.activeTrack]: Active deck track only.
/// - [AudioOutputSource.standbyTrack]: Standby deck track only (pre-listening / cueing).
class AudioOutput {
  /// The unique operating system device identifier, or null for the automatic default device.
  final String? deviceId;

  /// Whether exclusive hardware access mode should be requested (e.g. WASAPI exclusive).
  final bool exclusiveMode;

  /// The audio signal routing source stream. Defaults to [AudioOutputSource.all].
  final AudioOutputSource source;

  /// Creates a unified [AudioOutput] destination.
  const AudioOutput({
    this.deviceId,
    this.exclusiveMode = false,
    this.source = AudioOutputSource.all,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioOutput &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          exclusiveMode == other.exclusiveMode &&
          source == other.source;

  @override
  int get hashCode => Object.hash(deviceId, exclusiveMode, source);

  @override
  String toString() =>
      'AudioOutput(deviceId: $deviceId, exclusiveMode: $exclusiveMode, source: $source)';
}

/// Real-time capture configuration parameters for an [AudioInput].
class AudioInputConfig {
  /// The linear capture input gain/volume multiplier (`>= 0.0`). Defaults to `1.0`.
  final double volume;

  /// Optional sidechain ducking configuration. When non-null and enabled, this input's
  /// voice signal attenuates the music deck bus during speech.
  final DuckingConfig? ducking;

  /// Whether low-latency direct pass-through monitoring to the master output is enabled.
  /// When `true`, this input's signal is routed directly to the master output.
  final bool monitorDirect;

  /// The linear volume multiplier for direct voice monitoring (`>= 0.0`). Defaults to `1.0`.
  final double monitorVolume;

  /// Creates an [AudioInputConfig] with the specified capture parameters.
  const AudioInputConfig({
    this.volume = 1.0,
    this.ducking,
    this.monitorDirect = false,
    this.monitorVolume = 1.0,
  });

  /// Creates a copy of this configuration with the given fields replaced.
  AudioInputConfig copyWith({
    double? volume,
    DuckingConfig? ducking,
    bool? monitorDirect,
    double? monitorVolume,
  }) {
    return AudioInputConfig(
      volume: volume ?? this.volume,
      ducking: ducking ?? this.ducking,
      monitorDirect: monitorDirect ?? this.monitorDirect,
      monitorVolume: monitorVolume ?? this.monitorVolume,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInputConfig &&
          volume == other.volume &&
          ducking == other.ducking &&
          monitorDirect == other.monitorDirect &&
          monitorVolume == other.monitorVolume;

  @override
  int get hashCode => Object.hash(
        volume,
        ducking,
        monitorDirect,
        monitorVolume,
      );

  @override
  String toString() =>
      'AudioInputConfig(volume: $volume, ducking: $ducking, monitorDirect: $monitorDirect, monitorVolume: $monitorVolume)';
}

/// Represents an active or requested hardware audio capture source.
class AudioInput {
  final String? _deviceId;

  /// The physical OS hardware audio capture device identifier (`null` or `'auto'` targets default).
  String? get deviceId => _deviceId;

  final AudioInputConfig _config;

  /// Real-time capture configuration (gain, ducking, direct monitoring).
  AudioInputConfig get config => _config;

  /// Creates an [AudioInput] bound to a hardware endpoint and an [AudioInputConfig].
  AudioInput({
    String? deviceId,
    AudioDevice? device,
    AudioInputConfig config = const AudioInputConfig(),
  })  : _deviceId = deviceId ?? device?.id,
        _config = config;

  /// Creates a copy of this input with updated parameters.
  AudioInput copyWith({
    String? deviceId,
    AudioDevice? device,
    AudioInputConfig? config,
  }) {
    return AudioInput(
      deviceId: deviceId ?? (device != null ? device.id : _deviceId),
      config: config ?? _config,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInput && _deviceId == other._deviceId;

  @override
  int get hashCode => _deviceId.hashCode;

  @override
  String toString() =>
      'AudioInput(deviceId: $_deviceId, config: $_config)';
}

/// Descriptor of an audio effect registered in the player's sound effects catalog.
class AudioEffect {
  /// The unique string identifier for this effect.
  final String id;

  /// The audio source to be decoded on demand into RAM.
  final AudioSource source;

  /// The maximum number of simultaneous voices allowed for this effect.
  final int maxPolyphony;

  /// Whether this effect is pinned to prevent cache eviction under memory pressure.
  final bool pinned;

  /// Creates an [AudioEffect] descriptor.
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

  /// Raw native enum value.
  final int value;
  const DspRouting(this.value);

  /// Resolves a [DspRouting] from its raw integer [val].
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

  /// Raw native enum value.
  final int value;
  const VoiceStealingPolicy(this.value);

  /// Resolves a [VoiceStealingPolicy] from its raw integer [val].
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
  /// The volume gain multiplier (`>= 0.0`).
  final double volume;

  /// The stereo balance panning (`-1.0` full left to `1.0` full right).
  final double balance;

  /// The pitch shift multiplier (`> 0.0`).
  final double pitch;

  /// The playback speed rate multiplier (`> 0.0`).
  final double rate;

  /// Whether the voice should loop continuously until explicitly stopped.
  final bool looping;

  /// The playback priority (`0` to `255`, higher values are prioritized over lower ones).
  final int priority;

  /// The randomized pitch jitter range applied to prevent acoustic repetition fatigue.
  final double pitchJitter;

  /// The randomized volume jitter range applied to prevent acoustic repetition fatigue.
  final double volumeJitter;

  /// Optional 3D spatial emitter parameters for spatial audio and Doppler simulation.
  final SpatialEmitter? spatial;

  /// Optional per-voice 10-band equalizer settings.
  final Equalizer? equalizer;

  /// Optional per-voice studio algorithmic reverb settings.
  final Reverb? reverb;

  /// The voice stealing policy when the polyphony limit is reached.
  final VoiceStealingPolicy stealingPolicy;

  /// The maximum number of simultaneous instances of this effect voice.
  final int maxPolyphony;

  /// The DSP pipeline routing mode (inherit, isolate, or bypass).
  final DspRouting dspRouting;

  /// Whether this voice is protected from LRU voice stealing.
  final bool pinned;

  /// Creates an [EffectConfig] with custom voice parameters.
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

  /// Returns a copy of this [EffectConfig] with modified properties.
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

/// Configuration parameters governing `MiniaudioPlayer` behavior.
class PlayerConfig {
  /// The audio hardware output sample rate in Hz (e.g. 44100, 48000).
  final int sampleRate;

  /// The number of audio output channels (typically 2 for stereo).
  final int channels;

  /// The audio buffer size in frames.
  final int bufferSizeFrames;

  /// The maximum number of concurrent polyphonic effect voices.
  final int maxVoices;

  /// Maximum memory budget in megabytes (MB) allocated for decoded RAM sound effects.
  ///
  /// Defaults to `50` (50 MB).
  ///
  /// > [!CAUTION]
  /// > **[DANGEROUS: UNLIMITED MEMORY]**: Setting `effectMemoryLimitMb: null` disables all RAM eviction.
  /// > Sound effects will accumulate in memory indefinitely without safety boundaries. Use only in
  /// > strictly controlled environments with finite, small audio assets.
  final int? effectMemoryLimitMb;

  /// Optional exact byte-granularity override for the RAM sound effects memory budget.
  ///
  /// When non-null, takes precedence over [effectMemoryLimitMb].
  final int? maxRamBytes;

  /// Resolves the effective RAM budget in bytes (`null` for unlimited memory).
  int? get resolvedMaxRamBytes {
    if (maxRamBytes != null) return maxRamBytes;
    if (effectMemoryLimitMb != null) {
      return effectMemoryLimitMb! * 1024 * 1024;
    }
    return null;
  }

  /// The voice stealing policy when max voices are saturated.
  final VoiceStealingPolicy voiceStealingPolicy;

  /// Whether audio should automatically play when an audio source is loaded.
  final bool autoPlay;

  /// Whether playback should automatically pause when the active audio device disconnects.
  final bool pauseOnDeviceChange;

  /// The target prefetch buffer duration for local files.
  final Duration bufferLocalDuration;

  /// The target prefetch buffer duration for network streams.
  final Duration bufferNetworkDuration;

  /// The default crossfade configuration for track transitions.
  final CrossfadeConfig? crossfade;

  /// Whether 3D spatial audio processing is enabled.
  final bool enableSpatialAudio;

  /// Creates a [PlayerConfig] with engine parameters.
  const PlayerConfig({
    this.sampleRate = 48000,
    this.channels = 2,
    this.bufferSizeFrames = 1024,
    this.maxVoices = 64,
    this.effectMemoryLimitMb = 50,
    this.maxRamBytes,
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
  /// The file path on disk where the recording was saved.
  final String path;

  /// The total duration of the recorded audio.
  final Duration duration;

  /// The total number of bytes written to the file.
  final int bytesWritten;

  /// The total number of PCM frames/samples written.
  final int sampleCount;

  /// Creates a [RecordingResult] summarizing a completed recording.
  const RecordingResult({
    required this.path,
    required this.duration,
    required this.bytesWritten,
    required this.sampleCount,
  });
}
