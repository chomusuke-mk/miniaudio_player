import '../rust/api/types.dart' as rust_types;

/// Bitrate encoding mode of an audio stream.
enum BitrateMode {
  /// Bitrate mode could not be determined or is not applicable.
  unknown,

  /// Constant Bitrate (CBR).
  cbr,

  /// Variable Bitrate (VBR).
  vbr;

  /// Converts a native `RustBitrateMode` [mode] into a [BitrateMode].
  static BitrateMode fromRust(rust_types.RustBitrateMode mode) =>
      switch (mode) {
        rust_types.RustBitrateMode.cbr => BitrateMode.cbr,
        rust_types.RustBitrateMode.vbr => BitrateMode.vbr,
        rust_types.RustBitrateMode.unknown => BitrateMode.unknown,
      };
}

/// Core technical audio properties extracted at zero cost from container and codec headers.
///
/// Includes [sampleRate], [rawSampleRate], [channels], [bitsPerSample], [duration],
/// [bitrate], [bitrateMode], [codec], [containerFormat], [lossless], and [fileSize].
class AudioInfo {
  /// Total duration of the audio track, or `null` if unknown or infinite (for example, a livestream).
  final Duration? duration;

  /// Decoded output PCM audio sample rate in Hz (for example, `44100`, `48000`, `88200`, or `352800`).
  final int sampleRate;

  /// Native stream sample rate in Hz before decimation when it differs from [sampleRate],
  /// or `null` otherwise.
  ///
  /// For example, DSD64 has a [rawSampleRate] of `2822400` Hz and a decimated [sampleRate] of `352800` Hz PCM.
  final int? rawSampleRate;

  /// Number of audio channels (for example, `1` for Mono or `2` for Stereo).
  final int channels;

  /// Bit depth per sample (for example, `16`, `24`, `32`, or `1` for 1-bit DSD), or `null` for lossy codecs
  /// without a fixed PCM bit depth.
  final int? bitsPerSample;

  /// Average nominal bitrate of the track in bits per second (bps).
  final int bitrate;

  /// Short container or codec format identifier (for example, `"mp3"`, `"flac"`, `"wav"`, or `"aac"`),
  /// or `null` if unspecified.
  final String? format;

  /// Canonical codec name (for example, `"MP3"`, `"FLAC"`, `"AAC"`, `"ALAC"`, `"Opus"`, `"Vorbis"`,
  /// `"PCM"`, `"DSD"`, `"APE"`, or `"WavPack"`).
  final String codec;

  /// Canonical container format (for example, `"MP3"`, `"FLAC"`, `"MP4"`, `"Ogg"`, `"WAV"`, `"RF64"`,
  /// `"W64"`, `"RIFX"`, `"AIFF"`, `"CAF"`, `"Matroska"`, `"DSF"`, `"APE"`, `"WavPack"`,
  /// `"ADTS"`, or `"HLS"`).
  final String containerFormat;

  /// Whether the audio codec is lossless (`true` for PCM, FLAC, ALAC, WavPack, APE, and DSD).
  final bool lossless;

  /// Bitrate encoding mode ([BitrateMode.cbr], [BitrateMode.vbr], or [BitrateMode.unknown]).
  final BitrateMode bitrateMode;

  /// Total file or stream size in bytes when known, or `null` for unbounded or live streams.
  final int? fileSize;

  /// Creates an immutable [AudioInfo] instance.
  ///
  /// Requires [sampleRate], [channels], and [bitrate], with optional [duration], [rawSampleRate],
  /// [bitsPerSample], [format], [codec], [containerFormat], [lossless], [bitrateMode], and [fileSize].
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

  /// Creates an [AudioInfo] from a native `RustAudioInfo` struct [r].
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

  /// Compares this [AudioInfo] with [other] for value equality.
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

  /// Returns a hash code combining all technical audio properties.
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

  /// Returns a readable string summary of this [AudioInfo].
  @override
  String toString() =>
      'AudioInfo(duration: $duration, sampleRate: $sampleRate Hz'
      '${rawSampleRate != null ? ' (raw: $rawSampleRate Hz)' : ''}, '
      'channels: $channels, bitsPerSample: $bitsPerSample, '
      'bitrate: ${bitrate ~/ 1000} kbps (${bitrateMode.name}), '
      'codec: $codec, containerFormat: $containerFormat, '
      'lossless: $lossless, format: $format, fileSize: $fileSize)';
}
