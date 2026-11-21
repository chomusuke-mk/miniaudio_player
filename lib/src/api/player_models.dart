import 'dart:typed_data';

import '../equalizer.dart';
import '../loader/recording_result_helper.dart';
import '../reverb.dart';
import 'crossfade_config.dart';
import 'miniaudio_player.dart';
import 'player_exception.dart';
import 'recording.dart' show DuckingConfig, WavFormat;
import 'recording_byte_buffer.dart';
import 'spatial.dart';

/// Formats defined for live audio recording sinks.
enum AudioFileFormat {
  /// Uncompressed 16-bit signed PCM WAV (`RIFF`/`WAVE`).
  wav(
    wireCode: 0,
    extension: 'wav',
    mimeType: 'audio/wav',
    shortLabel: 'WAV 16',
    displayLabel: 'WAV (PCM 16-bit)',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// MP3 compressed audio stream (unsupported — no MP3 encoder in current crates).
  mp3(
    wireCode: -1,
    extension: 'mp3',
    mimeType: 'audio/mpeg',
    shortLabel: 'MP3',
    displayLabel: 'MP3',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// FLAC lossless compressed audio stream (unsupported — no FLAC encoder in current crates).
  flac(
    wireCode: -1,
    extension: 'flac',
    mimeType: 'audio/flac',
    shortLabel: 'FLAC',
    displayLabel: 'FLAC',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// Uncompressed 32-bit IEEE floating-point PCM WAV (`RIFF`/`WAVE`).
  wavFloat32(
    wireCode: 1,
    extension: 'wav',
    mimeType: 'audio/wav',
    shortLabel: 'WAV 32F',
    displayLabel: 'WAV (Float 32-bit)',
    isFloat32: true,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// 64-bit extended WAV (`RF64` + `ds64`), 16-bit signed integer PCM (>4 GiB safe).
  rf64(
    wireCode: 2,
    extension: 'rf64',
    mimeType: 'audio/x-rf64',
    shortLabel: 'RF64 16',
    displayLabel: 'RF64 (>4GB PCM 16)',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// 64-bit extended WAV (`RF64` + `ds64`), 32-bit IEEE float PCM (>4 GiB safe).
  rf64Float32(
    wireCode: 3,
    extension: 'rf64',
    mimeType: 'audio/x-rf64',
    shortLabel: 'RF64 32F',
    displayLabel: 'RF64 (>4GB Float 32)',
    isFloat32: true,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// Sony Wave64 (`w64` GUID chunks), 16-bit signed integer PCM (>4 GiB safe).
  w64(
    wireCode: 4,
    extension: 'w64',
    mimeType: 'audio/x-w64',
    shortLabel: 'W64 16',
    displayLabel: 'Wave64 (PCM 16)',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// Sony Wave64 (`w64` GUID chunks), 32-bit IEEE float PCM (>4 GiB safe).
  w64Float32(
    wireCode: 5,
    extension: 'w64',
    mimeType: 'audio/x-w64',
    shortLabel: 'W64 32F',
    displayLabel: 'Wave64 (Float 32)',
    isFloat32: true,
    isBigEndian: false,
    isWavPack: false,
  ),

  /// Audio Interchange File Format (`FORM`/`AIFF`), big-endian 16-bit signed PCM.
  aiff(
    wireCode: 6,
    extension: 'aiff',
    mimeType: 'audio/aiff',
    shortLabel: 'AIFF 16',
    displayLabel: 'AIFF (PCM 16-bit)',
    isFloat32: false,
    isBigEndian: true,
    isWavPack: false,
  ),

  /// Apple Core Audio Format (`caff`/`lpcm`), big-endian 16-bit signed PCM (>4 GiB safe).
  caf(
    wireCode: 7,
    extension: 'caf',
    mimeType: 'audio/x-caf',
    shortLabel: 'CAF 16',
    displayLabel: 'CAF (PCM 16-bit)',
    isFloat32: false,
    isBigEndian: true,
    isWavPack: false,
  ),

  /// Apple Core Audio Format (`caff`/`lpcm`), big-endian 32-bit IEEE float PCM (>4 GiB safe).
  cafFloat32(
    wireCode: 8,
    extension: 'caf',
    mimeType: 'audio/x-caf',
    shortLabel: 'CAF 32F',
    displayLabel: 'CAF (Float 32-bit)',
    isFloat32: true,
    isBigEndian: true,
    isWavPack: false,
  ),

  /// Lossless compressed WavPack (`.wv`) 16-bit signed integer PCM.
  wavPack(
    wireCode: 9,
    extension: 'wv',
    mimeType: 'audio/x-wavpack',
    shortLabel: 'WV 16',
    displayLabel: 'WavPack (Lossless 16)',
    isFloat32: false,
    isBigEndian: false,
    isWavPack: true,
  ),

  /// Lossless compressed WavPack (`.wv`) 32-bit IEEE float PCM.
  wavPackFloat32(
    wireCode: 10,
    extension: 'wv',
    mimeType: 'audio/x-wavpack',
    shortLabel: 'WV 32F',
    displayLabel: 'WavPack (Lossless F32)',
    isFloat32: true,
    isBigEndian: false,
    isWavPack: true,
  );

  /// Stable wire identifier matching Rust `RecordingEncoding` (`-1` when unsupported).
  final int wireCode;

  /// Canonical file extension without a leading dot (e.g., `'wav'`, `'rf64'`, `'wv'`).
  final String extension;

  /// Standard MIME type used when exporting Web Blobs or launching viewers.
  final String mimeType;

  /// Compact badge label for narrow dropdown triggers (e.g., `'WAV 16'`, `'WV 32F'`).
  final String shortLabel;

  /// Human-readable display label for UI selectors.
  final String displayLabel;

  /// Whether samples are stored as 32-bit IEEE floating point instead of 16-bit integer PCM.
  final bool isFloat32;

  /// Whether raw sample bytes use big-endian byte order (AIFF, CAF).
  final bool isBigEndian;

  /// Whether blocks are compressed losslessly with WavPack (`wavicle`).
  final bool isWavPack;

  const AudioFileFormat({
    required this.wireCode,
    required this.extension,
    required this.mimeType,
    required this.shortLabel,
    required this.displayLabel,
    required this.isFloat32,
    required this.isBigEndian,
    required this.isWavPack,
  });

  /// Whether this format can be encoded during live recording.
  bool get isSupportedForRecording => wireCode >= 0;

  /// Bits per uncompressed PCM sample (`16` or `32`).
  int get bitsPerSample => isFloat32 ? 32 : 16;

  /// Maximum payload byte limit for 32-bit containers, or `null` when >4 GiB safe.
  int? get maxPayloadBytes {
    if (this == wav || this == wavFloat32) return 0xFFFFFFFF - 36;
    if (this == aiff) return 0xFFFFFFFF - 46;
    return null;
  }

  /// All formats supported by the built-in real-time encoders.
  static List<AudioFileFormat> get supportedRecordingFormats =>
      values.where((f) => f.isSupportedForRecording).toList(growable: false);

  static const Map<AudioFileFormat, AudioFileFormat> _float32Pairs = {
    wav: wavFloat32,
    rf64: rf64Float32,
    w64: w64Float32,
    caf: cafFloat32,
    wavPack: wavPackFloat32,
  };

  static const Map<AudioFileFormat, AudioFileFormat> _pcm16Pairs = {
    wavFloat32: wav,
    rf64Float32: rf64,
    w64Float32: w64,
    cafFloat32: caf,
    wavPackFloat32: wavPack,
    aiff: aiff,
  };

  /// Validates this format for live recording and resolves an optional [wavFormat] bit-depth override.
  ///
  /// Throws [MiniaudioPlayerException] with [MapResult.errorUnsupported] when the format
  /// (or requested bit depth for that container, e.g. 32-bit float AIFF) cannot be encoded.
  AudioFileFormat resolveForRecording({WavFormat? wavFormat}) {
    if (!isSupportedForRecording) {
      throw MiniaudioPlayerException(
        'Live recording to ${name.toUpperCase()} is not supported yet. '
        'Supported formats: WAV, RF64, W64, AIFF, CAF, WavPack.',
        errorCode: MapResult.errorUnsupported,
      );
    }
    if (wavFormat == null) return this;
    final resolved = wavFormat == WavFormat.float32
        ? (_float32Pairs[this] ?? (isFloat32 ? this : null))
        : (_pcm16Pairs[this] ?? (!isFloat32 ? this : null));
    if (resolved == null) {
      throw MiniaudioPlayerException(
        'Container ${name.toUpperCase()} does not support ${wavFormat.name}.',
        errorCode: MapResult.errorUnsupported,
      );
    }
    return resolved;
  }

  /// Converts this [AudioFileFormat] to its corresponding [WavFormat].
  ///
  /// Throws [MiniaudioPlayerException] with [MapResult.errorUnsupported] when
  /// the requested format cannot be encoded directly during live recording.
  WavFormat toWavFormat() {
    resolveForRecording();
    return isFloat32 ? WavFormat.float32 : WavFormat.pcm16;
  }
}

/// Audio signal source routed to an output device, live file recording session, or visualizer.
enum AudioOutputSource {
  /// Complete master mix (music + SFX voices + microphone + ducking + master limiter).
  all(0),

  /// Pure music mix from decks with music DSP (EQ, Reverb), excluding SFX and microphone.
  musicMix(1),

  /// Isolated active deck track only.
  activeTrack(2),

  /// Isolated standby deck track only (ideal for DJ pre-listening).
  standbyTrack(3),

  /// Isolated microphone capture voice signal only, excluding music and sound effects.
  voiceOnly(4);

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
      case 4:
        return AudioOutputSource.voiceOnly;
      case 0:
      default:
        return AudioOutputSource.all;
    }
  }
}

/// Represents a hardware or virtual audio playback destination.
///
/// When [deviceId] is `'AUTO'`, the player routes audio dynamically to the operating system's
/// default audio output endpoint.
///
/// [source] determines which audio stream is routed to this endpoint:
/// - [AudioOutputSource.all]: Complete master mix (playback tracks + sound effects + mic).
/// - [AudioOutputSource.musicMix]: Pure music mix from decks, excluding SFX and mic.
/// - [AudioOutputSource.activeTrack]: Active deck track only.
/// - [AudioOutputSource.standbyTrack]: Standby deck track only (pre-listening / cueing).
///
/// ### Physical Endpoint Collision Resolution
/// If the player's active outputs contain both `'AUTO'` and a specific physical device ID
/// whose internal hardware endpoint matches the OS default endpoint (for example, `'AUTO'`
/// routing to default device ID 3, alongside an explicit output targeting device ID 3 with
/// different sources), the native Rust audio engine deduplicates the physical endpoint to
/// prevent double-streaming audio to the same hardware DAC.
///
/// In this scenario, `'AUTO'` and its associated configuration (source stream) take strict
/// precedence over specific device configurations for physical hardware rendering.
/// The declared set in `state.outputs` and `stream.outputs` remains completely intact and
/// unmodified, preserving all user-selected items.
class AudioOutput {
  /// The operating system hardware device identifier, or 'AUTO' for system default.
  final String deviceId;

  /// The audio signal routing source stream. Defaults to [AudioOutputSource.all].
  final AudioOutputSource source;

  /// Creates a unified [AudioOutput] destination.
  const AudioOutput({
    this.deviceId = 'AUTO',
    this.source = AudioOutputSource.all,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioOutput &&
          runtimeType == other.runtimeType &&
          deviceId == other.deviceId &&
          source == other.source;

  @override
  int get hashCode => Object.hash(deviceId, source);

  @override
  String toString() => 'AudioOutput(deviceId: $deviceId, source: $source)';
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
///
/// When [deviceId] is `'AUTO'`, the player captures audio from the operating system's
/// default microphone / input endpoint.
///
/// ### Physical Endpoint Collision Resolution
/// If the player's active inputs contain both `'AUTO'` and a specific physical device ID
/// whose internal hardware endpoint matches the OS default capture endpoint (for example,
/// `'AUTO'` alongside an explicit input targeting the same physical microphone), the native
/// Rust audio engine deduplicates physical endpoints to prevent duplicate hardware capture
/// and driver lock contention.
///
/// In this scenario, `'AUTO'` and its associated configuration (gain, ducking parameters)
/// take strict precedence over specific input configurations for physical capture.
/// The declared set in `state.inputs` and `stream.inputs` remains completely intact and
/// unmodified, preserving all user-selected items.
class AudioInput {
  final String _deviceId;

  /// The physical OS hardware audio capture device identifier (`'AUTO'` targets default).
  String get deviceId => _deviceId;

  final AudioInputConfig _config;

  /// Real-time capture configuration (gain, ducking, direct monitoring).
  AudioInputConfig get config => _config;

  /// Creates an [AudioInput] bound to a hardware endpoint and an [AudioInputConfig].
  const AudioInput({
    String deviceId = 'AUTO',
    AudioInputConfig config = const AudioInputConfig(),
  })  : _deviceId = deviceId,
        _config = config;

  /// Creates a copy of this input with updated parameters.
  AudioInput copyWith({
    String? deviceId,
    AudioInputConfig? config,
  }) {
    return AudioInput(
      deviceId: deviceId ?? _deviceId,
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
  String toString() => 'AudioInput(deviceId: $_deviceId, config: $_config)';
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

  /// Maximum memory budget in bytes allocated for decoded RAM sound effects.
  ///
  /// Defaults to `50 * 1024 * 1024` (50 MB).
  ///
  /// > [!CAUTION]
  /// > **[DANGEROUS: UNLIMITED MEMORY]**: Setting `maxRamBytes: null` disables all RAM eviction.
  /// > Sound effects will accumulate in memory indefinitely without safety boundaries. Use only in
  /// > strictly controlled environments with finite, small audio assets.
  final int? maxRamBytes;

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

  /// The audio signal source that feeds the real-time FFT spectrum visualizer.
  ///
  /// Defaults to [AudioOutputSource.all].
  final AudioOutputSource visualizerSource;

  /// Creates a [PlayerConfig] with engine parameters.
  const PlayerConfig({
    this.sampleRate = 44100,
    this.channels = 2,
    this.bufferSizeFrames = 0,
    this.maxVoices = 64,
    this.maxRamBytes = 50 * 1024 * 1024,
    this.voiceStealingPolicy = VoiceStealingPolicy.lowestPriority,
    this.autoPlay = false,
    this.pauseOnDeviceChange = false,
    this.bufferLocalDuration = const Duration(seconds: 30),
    this.bufferNetworkDuration = const Duration(seconds: 30),
    this.crossfade,
    this.enableSpatialAudio = true,
    this.visualizerSource = AudioOutputSource.all,
  });
}

/// Immutable record summarizing the metrics and output target of a completed audio recording,
/// with ergonomic helpers for browser downloads, byte reads, direct playback, and cleanup.
///
/// When recorded on Web using a relative or absolute path (or optional `opfs://` prefix),
/// [isOpfs] is `true` and [path] holds the canonical sanitized OPFS path without any `opfs://`
/// prefix (e.g. `'temporal/sistema/test/1.wav'`).
class RecordingResult {
  /// Canonical destination path: local filesystem path or `content://` URI on Native,
  /// canonical OPFS path without `opfs://` prefix on Web ([isOpfs] == `true`), or `''`
  /// when recorded into an unnamed [MemoryRecordingBuffer].
  final String path;

  /// The total duration of the recorded audio.
  final Duration duration;

  /// The total number of encoded audio payload bytes written to the sink.
  final int bytesWritten;

  /// The total number of PCM channel samples captured.
  final int sampleCount;

  /// Number of PCM frames dropped due to writer backpressure or ring overflow.
  final int droppedFrames;

  /// Container/encoding format used when creating this recording, if known.
  final AudioFileFormat? format;

  /// Whether [path] refers to a browser Origin Private File System (OPFS) file on Web.
  final bool isOpfs;

  final MemoryRecordingBuffer? _memoryBuffer;

  /// Creates a [RecordingResult] summarizing a completed recording.
  const RecordingResult({
    required this.path,
    required this.duration,
    required this.bytesWritten,
    required this.sampleCount,
    this.droppedFrames = 0,
    this.format,
    this.isOpfs = false,
    MemoryRecordingBuffer? memoryBuffer,
  }) : _memoryBuffer = memoryBuffer;

  /// Canonical leaf file name extracted from [path], falling back to `'recording.<ext>'`
  /// when recorded into an unnamed in-memory buffer.
  String get fileName {
    final trimmed = path.trim();
    if (trimmed.isNotEmpty) {
      final parts = trimmed.split(RegExp(r'[/\\]'));
      for (var i = parts.length - 1; i >= 0; i--) {
        if (parts[i].isNotEmpty) return parts[i];
      }
    }
    final ext = format?.extension ?? 'wav';
    return 'recording.$ext';
  }

  /// Resolved MIME type for this recording based on [format] or [path] file extension.
  String get mimeType {
    final explicit = format?.mimeType;
    if (explicit != null) return explicit;
    final lower = path.toLowerCase();
    if (lower.endsWith('.rf64')) return 'audio/x-rf64';
    if (lower.endsWith('.w64')) return 'audio/x-w64';
    if (lower.endsWith('.aiff') || lower.endsWith('.aif')) return 'audio/aiff';
    if (lower.endsWith('.caf')) return 'audio/x-caf';
    if (lower.endsWith('.wv')) return 'audio/x-wavpack';
    return 'audio/wav';
  }

  /// Whether this recording is held in a built-in [MemoryRecordingBuffer].
  bool get isInMemory => _memoryBuffer != null;

  /// Triggers a direct browser file download on Web (`true` when initiated) using
  /// an $O(1)$-RAM disk-backed `File` handle for OPFS results or the recorded chunks for
  /// [MemoryRecordingBuffer] results. Returns `false` on non-Web targets or empty sources.
  Future<bool> download({String? fileName}) async {
    final targetName = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : this.fileName;
    if (isOpfs && path.trim().isNotEmpty) {
      return downloadOpfsRecordingFile(
        path,
        fileName: targetName,
        mimeType: mimeType,
      );
    }
    final mem = _memoryBuffer;
    if (mem != null) {
      return downloadMemoryRecordingBytes(
        mem.chunks,
        fileName: targetName,
        mimeType: mimeType,
      );
    }
    return false;
  }

  /// Reads all finalized container + audio bytes into memory.
  Future<Uint8List> readBytes() async {
    final mem = _memoryBuffer;
    if (mem != null) return mem.toBytes();
    if (isOpfs) return readOpfsRecordingBytes(path);
    return readDiskRecordingBytes(path);
  }

  /// Converts this completed recording directly into an [AudioSource<D>] suitable for
  /// `player.action.load(...)`, `setQueue(...)`, or `MiniaudioPlayer.analyzeAudio(...)`.
  ///
  /// For Web OPFS and native disk paths, this points directly to [path] ($O(1)$ RAM).
  /// For [MemoryRecordingBuffer], passes the encoded bytes to the native engine.
  AudioSource<D> toAudioSource<D>({D? data}) {
    final mem = _memoryBuffer;
    if (mem != null) {
      final bytes = mem.toBytes();
      if (bytes.isEmpty) {
        throw const MiniaudioPlayerException(
          'Cannot create AudioSource from an empty or cleared recording buffer.',
          errorCode: MapResult.errorInvalidState,
        );
      }
      return AudioSource<D>(bytes, data: data);
    }
    if (path.trim().isEmpty) {
      throw const MiniaudioPlayerException(
        'Cannot create AudioSource: recording has no file path or MemoryRecordingBuffer.',
        errorCode: MapResult.errorInvalidState,
      );
    }
    return AudioSource<D>(path, data: data);
  }

  /// Creates an on-demand browser `blob:` URI (`$O(1)` RAM disk-backed for OPFS files)
  /// for `<audio>` elements, Web Share, or external JS consumers; returns `null` off Web.
  ///
  /// Call [revokeBlobUri] once the URL is no longer needed.
  Future<Uri?> createBlobUri({String? fileName}) async {
    final targetName = fileName ?? this.fileName;
    if (isOpfs && path.trim().isNotEmpty) {
      return createOpfsRecordingBlobUri(
        path,
        mimeType: mimeType,
        fileName: targetName,
      );
    }
    final mem = _memoryBuffer;
    if (mem != null) {
      return createMemoryRecordingBlobUri(
        mem.chunks,
        mimeType: mimeType,
        fileName: targetName,
      );
    }
    return null;
  }

  /// Revokes a Web `blob:` [Uri] previously created by [createBlobUri].
  static void revokeBlobUri(Uri? uri) => revokeRecordingResultBlobUri(uri);

  /// Returns whether this recording still exists in OPFS, on local disk, or with data in RAM.
  Future<bool> exists() async {
    final mem = _memoryBuffer;
    if (mem != null) return mem.lengthInBytes > 0;
    if (isOpfs) return opfsRecordingFileExists(path);
    return diskRecordingFileExists(path);
  }

  /// Deletes the recorded file (on OPFS or native disk) or clears the in-memory buffer.
  /// Returns `true` if data was deleted/cleared.
  Future<bool> delete() async {
    final mem = _memoryBuffer;
    if (mem != null) {
      final hadData = mem.lengthInBytes > 0;
      mem.clear();
      return hadData;
    }
    if (isOpfs) return deleteOpfsRecordingFile(path);
    return deleteDiskRecordingFile(path);
  }

  /// Copies/saves this recording to [destinationPath] (local filesystem on Native,
  /// sanitized OPFS path on Web) and returns the canonical saved destination path.
  Future<String> saveTo(String destinationPath) => saveRecordingToDestination(
        destinationPath: destinationPath,
        sourcePath: path,
        sourceIsOpfs: isOpfs,
        memoryChunks: _memoryBuffer?.chunks,
      );
}
