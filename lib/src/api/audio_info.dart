import '../rust/api/types.dart' as rust_types;

/// Bitrate encoding mode of an audio stream.
enum BitrateMode {
  /// Bitrate mode could not be determined or is not applicable.
  unknown,

  /// Constant Bitrate (CBR).
  cbr,

  /// Variable Bitrate (VBR).
  vbr;

  /// Converts a native [rust_types.RustBitrateMode] into a [BitrateMode].
  static BitrateMode fromRust(rust_types.RustBitrateMode mode) =>
      switch (mode) {
        rust_types.RustBitrateMode.cbr => BitrateMode.cbr,
        rust_types.RustBitrateMode.vbr => BitrateMode.vbr,
        rust_types.RustBitrateMode.unknown => BitrateMode.unknown,
      };
}

/// Represents core technical audio information extracted at zero cost from
/// the container and codec headers (sample rate, raw sample rate, channel count,
/// bit depth, duration, nominal bitrate, bitrate mode, codec, container format,
/// lossless flag, and file size).
class AudioInfo {
  /// Total duration of the audio track, or `null` if unknown or infinite (e.g. livestream).
  final Duration? duration;

  /// Decoded output PCM audio sample rate in Hz (e.g. 44100, 48000, 88200, 352800).
  final int sampleRate;

  /// Native stream sample rate in Hz before decimation when it differs from [sampleRate]
  /// (e.g. `2822400` Hz for DSD64 where [sampleRate] is `352800` Hz PCM), or `null` otherwise.
  final int? rawSampleRate;

  /// Number of audio channels (e.g. 1 for Mono, 2 for Stereo).
  final int channels;

  /// Bit depth per sample (e.g. 16, 24, 32, or 1 for 1-bit DSD), or `null` for lossy codecs
  /// without a fixed PCM bit depth.
  final int? bitsPerSample;

  /// Average nominal bitrate of the track in bits per second (bps).
  final int bitrate;

  /// Short container or codec format identifier (e.g. `"mp3"`, `"flac"`, `"wav"`, `"aac"`).
  final String? format;

  /// Canonical codec name (e.g. `"MP3"`, `"FLAC"`, `"AAC"`, `"ALAC"`, `"Opus"`, `"Vorbis"`,
  /// `"PCM"`, `"DSD"`, `"APE"`, `"WavPack"`).
  final String codec;

  /// Canonical container format (e.g. `"MP3"`, `"FLAC"`, `"MP4"`, `"Ogg"`, `"WAV"`, `"RF64"`,
  /// `"W64"`, `"RIFX"`, `"AIFF"`, `"CAF"`, `"Matroska"`, `"DSF"`, `"APE"`, `"WavPack"`,
  /// `"ADTS"`, `"HLS"`).
  final String containerFormat;

  /// Whether the audio codec is lossless (`true` for PCM, FLAC, ALAC, WavPack, APE, DSD).
  final bool lossless;

  /// Bitrate encoding mode ([BitrateMode.cbr], [BitrateMode.vbr], or [BitrateMode.unknown]).
  final BitrateMode bitrateMode;

  /// Total file or stream size in bytes when known, or `null` for unbounded/live streams.
  final int? fileSize;

  /// Creates an immutable [AudioInfo] instance.
  const AudioInfo({
    this.duration,
    required this.sampleRate,
    this.rawSampleRate,
    required this.channels,
    this.bitsPerSample,
    required this.bitrate,
    this.format,
    this.codec = 'Unknown',
    this.containerFormat = 'Unknown',
    this.lossless = false,
    this.bitrateMode = BitrateMode.unknown,
    this.fileSize,
  });

  /// Creates an [AudioInfo] from a native [rust_types.RustAudioInfo] struct.
  factory AudioInfo.fromRust(rust_types.RustAudioInfo r) {
    final durMs = r.durationMs?.toInt();
    final dur =
        (durMs != null && durMs > 0) ? Duration(milliseconds: durMs) : null;
    final rawSr = (r.rawSampleRate != null && r.rawSampleRate! > 0)
        ? r.rawSampleRate
        : null;
    final bps = (r.bitsPerSample != null && r.bitsPerSample! > 0)
        ? r.bitsPerSample
        : null;
    final fSize = r.fileSize?.toInt();
    return AudioInfo(
      duration: dur,
      sampleRate: r.sampleRate,
      rawSampleRate: rawSr,
      channels: r.channels,
      bitsPerSample: bps,
      bitrate: r.bitrate,
      format: r.format,
      codec: r.codec.isEmpty ? 'Unknown' : r.codec,
      containerFormat:
          r.containerFormat.isEmpty ? 'Unknown' : r.containerFormat,
      lossless: r.lossless,
      bitrateMode: BitrateMode.fromRust(r.bitrateMode),
      fileSize: (fSize != null && fSize > 0) ? fSize : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInfo &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          sampleRate == other.sampleRate &&
          rawSampleRate == other.rawSampleRate &&
          channels == other.channels &&
          bitsPerSample == other.bitsPerSample &&
          bitrate == other.bitrate &&
          format == other.format &&
          codec == other.codec &&
          containerFormat == other.containerFormat &&
          lossless == other.lossless &&
          bitrateMode == other.bitrateMode &&
          fileSize == other.fileSize;

  @override
  int get hashCode => Object.hash(
        duration,
        sampleRate,
        rawSampleRate,
        channels,
        bitsPerSample,
        bitrate,
        format,
        codec,
        containerFormat,
        lossless,
        bitrateMode,
        fileSize,
      );

  @override
  String toString() =>
      'AudioInfo(duration: $duration, sampleRate: $sampleRate Hz'
      '${rawSampleRate != null ? ' (raw: $rawSampleRate Hz)' : ''}, '
      'channels: $channels, bitsPerSample: $bitsPerSample, '
      'bitrate: ${bitrate ~/ 1000} kbps (${bitrateMode.name}), '
      'codec: $codec, containerFormat: $containerFormat, '
      'lossless: $lossless, format: $format, fileSize: $fileSize)';
}
