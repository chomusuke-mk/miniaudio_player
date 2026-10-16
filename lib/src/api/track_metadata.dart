import 'dart:math';

/// Recognized audio codecs natively decoded by [MiniaudioPlayer].
enum AudioCodec {
  mp3('mp3'),
  aac('aac'),
  flac('flac'),
  opus('opus'),
  vorbis('vorbis'),
  pcm('pcm'),
  alac('alac'),
  unknown('unknown');

  final String name;
  const AudioCodec(this.name);

  /// Resolves the audio codec purely by header/magic bytes and optional MIME type,
  /// without inspecting file extensions or path names.
  static AudioCodec detect(List<int> bytes, {String? mime}) {
    if (bytes.length >= 4) {
      // 1. FLAC: 'fLaC' (0x66, 0x4C, 0x61, 0x43)
      if (bytes[0] == 0x66 && bytes[1] == 0x4C && bytes[2] == 0x61 && bytes[3] == 0x43) {
        return AudioCodec.flac;
      }

      // 2. Ogg Container: 'OggS'
      if (bytes[0] == 0x4F && bytes[1] == 0x67 && bytes[2] == 0x67 && bytes[3] == 0x53) {
        final probeLimit = min(256, bytes.length);
        final probeStr = String.fromCharCodes(bytes.sublist(0, probeLimit));
        if (probeStr.contains('OpusHead')) return AudioCodec.opus;
        if (probeStr.contains('vorbis')) return AudioCodec.vorbis;
        if (probeStr.contains('FLAC')) return AudioCodec.flac;
        if (mime != null && mime.toLowerCase().contains('opus')) return AudioCodec.opus;
        return AudioCodec.vorbis;
      }

      // 3. RIFF WAV / RF64 / BWF: 'RIFF' or 'RF64'
      if ((bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46) ||
          (bytes[0] == 0x52 && bytes[1] == 0x46 && bytes[2] == 0x36 && bytes[3] == 0x34)) {
        return AudioCodec.pcm;
      }

      // 4. AIFF: 'FORM'
      if (bytes[0] == 0x46 && bytes[1] == 0x4F && bytes[2] == 0x52 && bytes[3] == 0x4D) {
        return AudioCodec.pcm;
      }

      // 5. MP4 / M4A: 'ftyp' at offset 4
      if (bytes.length >= 8 &&
          bytes[4] == 0x66 &&
          bytes[5] == 0x74 &&
          bytes[6] == 0x79 &&
          bytes[7] == 0x70) {
        final probeLimit = min(4096, bytes.length);
        final headerStr = String.fromCharCodes(bytes.sublist(0, probeLimit));
        if (headerStr.contains('alac')) return AudioCodec.alac;
        return AudioCodec.aac;
      }

      // 6. MP3: ID3 header ('ID3')
      if (bytes[0] == 0x49 && bytes[1] == 0x44 && bytes[2] == 0x33) {
        return AudioCodec.mp3;
      }

      // 7. MP3 frame sync vs AAC ADTS
      if (bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
        if ((bytes[1] & 0x06) == 0x00) {
          return AudioCodec.aac;
        }
        return AudioCodec.mp3;
      }
    }

    if (mime != null && mime.isNotEmpty) {
      final lower = mime.toLowerCase();
      if (lower.contains('audio/mpeg') || lower.contains('audio/mp3')) return AudioCodec.mp3;
      if (lower.contains('audio/aac') || lower.contains('audio/x-aac')) return AudioCodec.aac;
      if (lower.contains('audio/mp4') || lower.contains('audio/m4a')) return AudioCodec.aac;
      if (lower.contains('audio/flac') || lower.contains('audio/x-flac')) return AudioCodec.flac;
      if (lower.contains('audio/opus')) return AudioCodec.opus;
      if (lower.contains('audio/ogg') || lower.contains('audio/vorbis')) return AudioCodec.vorbis;
      if (lower.contains('audio/wav') || lower.contains('audio/x-wav') || lower.contains('audio/pcm')) return AudioCodec.pcm;
    }

    return AudioCodec.unknown;
  }
}

/// Enumeration of recognized audio container and codec formats natively supported by [MiniaudioPlayer].
enum AudioFormat {
  mp3('mp3'),
  wav('wav'),
  flac('flac'),
  ogg('ogg'),
  opus('opus'),
  aac('aac'),
  m4a('m4a'),
  alac('alac'),
  aif('aif'),
  aiff('aiff'),
  aifc('aifc'),
  w64('w64'),
  rf64('rf64'),
  bwf('bwf'),
  rifx('rifx'),
  mp2('mp2'),
  mp1('mp1'),
  oga('oga'),
  unknown('unknown');

  final String extension;
  const AudioFormat(this.extension);

  static AudioFormat fromCodec(AudioCodec codec) {
    switch (codec) {
      case AudioCodec.mp3:
        return AudioFormat.mp3;
      case AudioCodec.aac:
        return AudioFormat.aac;
      case AudioCodec.flac:
        return AudioFormat.flac;
      case AudioCodec.opus:
        return AudioFormat.opus;
      case AudioCodec.vorbis:
        return AudioFormat.ogg;
      case AudioCodec.pcm:
        return AudioFormat.wav;
      case AudioCodec.alac:
        return AudioFormat.alac;
      case AudioCodec.unknown:
        return AudioFormat.unknown;
    }
  }

  static AudioFormat fromExtension(String ext) {
    final clean = ext.toLowerCase().replaceAll('.', '').trim();
    for (final fmt in AudioFormat.values) {
      if (fmt.extension == clean) return fmt;
    }
    return AudioFormat.unknown;
  }

  static AudioFormat fromMime(String mime) {
    final lower = mime.toLowerCase();
    if (lower.contains('audio/mpeg') || lower.contains('audio/mp3')) return AudioFormat.mp3;
    if (lower.contains('audio/wav') || lower.contains('audio/x-wav')) return AudioFormat.wav;
    if (lower.contains('audio/flac') || lower.contains('audio/x-flac')) return AudioFormat.flac;
    if (lower.contains('audio/ogg') || lower.contains('application/ogg')) return AudioFormat.ogg;
    if (lower.contains('audio/opus')) return AudioFormat.opus;
    if (lower.contains('audio/aac') || lower.contains('audio/x-aac')) return AudioFormat.aac;
    if (lower.contains('audio/mp4') || lower.contains('audio/m4a') || lower.contains('audio/x-m4a')) return AudioFormat.m4a;
    if (lower.contains('audio/aiff') || lower.contains('audio/x-aiff')) return AudioFormat.aiff;
    return AudioFormat.unknown;
  }
}

/// Comprehensive track metadata resolved upon opening and preserved across playback.
class AudioTrackMetadata {
  /// The detected audio codec (e.g. [AudioCodec.mp3], [AudioCodec.flac], [AudioCodec.aac]).
  final AudioCodec codec;

  /// The detected audio format / container.
  final AudioFormat format;

  /// Canonical format or codec label.
  final String formatName;

  /// Total duration of the track.
  final Duration duration;

  /// Total file size or HTTP Content-Length in bytes (-1 if unknown or live stream).
  final int totalBytes;

  /// Audio nominal bitrate in bits per second (bps), or 0 if uninitialized.
  final int bitrate;

  /// Audio sampling rate in Hz (e.g. 44100, 48000).
  final int sampleRate;

  /// Number of audio channels (e.g. 1 for mono, 2 for stereo).
  final int channels;

  /// Whether the track is loaded over network (HTTP/HTTPS).
  final bool isNetwork;

  /// Whether the track is an infinite / continuous livestream.
  final bool isLiveStream;

  /// Optional URI identifying the audio resource.
  final Uri? uri;

  /// Byte offset where the raw audio stream begins (skipping headers/metadata/cover art).
  final int audioDataOffset;

  const AudioTrackMetadata({
    required this.codec,
    required this.format,
    required this.formatName,
    required this.duration,
    required this.totalBytes,
    required this.bitrate,
    required this.sampleRate,
    required this.channels,
    required this.isNetwork,
    required this.isLiveStream,
    this.uri,
    this.audioDataOffset = 0,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrackMetadata &&
          runtimeType == other.runtimeType &&
          codec == other.codec &&
          format == other.format &&
          formatName == other.formatName &&
          duration == other.duration &&
          totalBytes == other.totalBytes &&
          bitrate == other.bitrate &&
          sampleRate == other.sampleRate &&
          channels == other.channels &&
          isNetwork == other.isNetwork &&
          isLiveStream == other.isLiveStream &&
          uri == other.uri &&
          audioDataOffset == other.audioDataOffset;

  @override
  int get hashCode => Object.hash(
        codec,
        format,
        formatName,
        duration,
        totalBytes,
        bitrate,
        sampleRate,
        channels,
        isNetwork,
        isLiveStream,
        uri,
        audioDataOffset,
      );

  @override
  String toString() =>
      'AudioTrackMetadata(codec: ${codec.name}, format: $formatName, duration: $duration, '
      'totalBytes: $totalBytes, audioOffset: $audioDataOffset, bitrate: ${bitrate ~/ 1000}kbps, '
      'channels: $channels, sampleRate: ${sampleRate}Hz, '
      'isNetwork: $isNetwork, isLive: $isLiveStream)';
}
