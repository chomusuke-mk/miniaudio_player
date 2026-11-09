/// Represents core technical audio information extracted at zero cost from
/// the container and codec headers (sample rate, channel count, duration,
/// nominal bitrate, and format).
class AudioInfo {
  /// Total duration of the audio track, or `null` if unknown or infinite (e.g. livestream).
  final Duration? duration;

  /// Native audio sample rate in Hz (e.g. 44100, 48000).
  final int sampleRate;

  /// Number of audio channels (e.g. 1 for Mono, 2 for Stereo).
  final int channels;

  /// Average nominal bitrate of the track in bits per second (bps).
  final int bitrate;

  /// Container or codec format identifier (e.g. "mp3", "flac", "wav", "aac").
  final String? format;

  /// Creates an immutable [AudioInfo] instance.
  const AudioInfo({
    this.duration,
    required this.sampleRate,
    required this.channels,
    required this.bitrate,
    this.format,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioInfo &&
          runtimeType == other.runtimeType &&
          duration == other.duration &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          bitrate == other.bitrate &&
          format == other.format;

  @override
  int get hashCode => Object.hash(
        duration,
        sampleRate,
        channels,
        bitrate,
        format,
      );

  @override
  String toString() =>
      'AudioInfo(duration: $duration, sampleRate: $sampleRate Hz, '
      'channels: $channels, bitrate: ${bitrate ~/ 1000} kbps, format: $format)';
}
