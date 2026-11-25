import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

/// View model describing an audio item inside the example player playlist.
class AudioTrack {
  /// Stable unique identifier for this track.
  final String id;

  /// Human-readable display title.
  final String title;

  /// Underlying [AudioSource] passed to the native player engine.
  final AudioSource source;

  /// Whether this track was synthesized dynamically as an in-memory WAV URI.
  final bool isGenerated;

  /// Optional artist attribution shown in queue and banner views.
  final String? artist;

  /// Optional album title associated with this track.
  final String? album;

  /// Optional ReplayGain track adjustment in decibels.
  final double? replayGainDb;

  /// Optional ReplayGain peak amplitude scalar.
  final double? replayPeak;

  /// Creates an [AudioTrack] descriptor for the example playlist with [id],
  /// [title], [source], and optional [isGenerated], [artist], [album],
  /// [replayGainDb], and [replayPeak] metadata.
  const AudioTrack({
    required this.id,
    required this.title,
    required this.source,
    this.isGenerated = false,
    this.artist,
    this.album,
    this.replayGainDb,
    this.replayPeak,
  });

  /// Returns the underlying URI string from [source], or an empty string.
  String get _sourceString => source.uri ?? '';

  /// Whether [source] targets an HTTP(S) or ICY network stream.
  bool get _isNetwork {
    final s = _sourceString.toLowerCase();
    return s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('icy://');
  }

  /// Whether [source] points to an HTTP Live Streaming (`.m3u8`) playlist.
  bool get isHlsVod =>
      _isNetwork && _sourceString.toLowerCase().contains('.m3u8');

  /// Whether [source] is an unbounded live radio or Icecast stream.
  bool get isLive {
    final s = _sourceString.toLowerCase();
    return _isNetwork &&
        (s.contains('/live') ||
            s.contains('icecast') ||
            s.startsWith('icy://'));
  }

  /// Whether single-pass offline acoustic analysis is supported for this track.
  bool get canAnalyze => true;

  /// Short uppercase badge label describing the transport scheme of [source].
  String get resourceBadge {
    if (isGenerated) return 'DATA URI';
    if (source.isCustom) return 'CUSTOM';
    if (source.isMemory) return 'MEMORY';
    if (isLive) return 'LIVE STREAM';
    if (isHlsVod) return 'HLS VOD';
    if (_isNetwork) return 'NETWORK';
    if (_sourceString.startsWith('asset:') ||
        _sourceString.startsWith('assets/')) {
      return 'ASSET';
    }
    return 'FILE';
  }

  /// Human-readable source scheme label shown in inspector views.
  String get displayType {
    if (isGenerated) return 'data: URI';
    if (source.isCustom) return 'CustomProvider';
    if (source.isMemory) return 'RAM Memory';
    if (isLive) return 'icy:// (Live)';
    if (isHlsVod) return 'https:// (HLS)';
    if (_isNetwork) return 'https://';
    if (_sourceString.startsWith('asset:') ||
        _sourceString.startsWith('assets/')) {
      return 'asset://';
    }
    return 'file://';
  }

  /// Representative Material icon corresponding to the [source] transport type.
  IconData get icon {
    if (isGenerated) return Icons.graphic_eq;
    if (source.isCustom) return Icons.alt_route;
    if (isLive) return Icons.radio;
    if (_isNetwork) return Icons.cloud_outlined;
    if (source.isMemory) return Icons.memory;
    if (_sourceString.startsWith('asset:') ||
        _sourceString.startsWith('assets/')) {
      return Icons.audiotrack;
    }
    return Icons.insert_drive_file_outlined;
  }

  /// Accent color associated with the [source] transport type.
  Color get iconColor {
    if (isGenerated) return Colors.amberAccent;
    if (source.isCustom) return Colors.orangeAccent;
    if (isLive) return Colors.redAccent;
    if (_isNetwork) return Colors.lightBlueAccent;
    if (source.isMemory) return Colors.purpleAccent;
    if (_sourceString.startsWith('asset:') ||
        _sourceString.startsWith('assets/')) {
      return Colors.tealAccent;
    }
    return Colors.greenAccent;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}

/// Format deduction helpers for displaying compact codec badges in the UI.
abstract final class TrackFormatInfo {
  /// Infers a short codec badge string for [track] using optional [sampleRate],
  /// [channels], and [bitrate] stream parameters.
  static String deduceFormatBadge(
    AudioTrack? track, {
    int sampleRate = 0,
    int channels = 0,
    int bitrate = 0,
  }) {
    if (track == null) return 'AUDIO ENGINE';
    final name = (track.source.uri ?? track.title).toLowerCase();

    if (name.endsWith('.flac')) {
      final rateStr = sampleRate > 0
          ? '${(sampleRate / 1000).toStringAsFixed(0)}kHz'
          : '96kHz';
      return 'FLAC $rateStr / 24-bit';
    }
    if (name.endsWith('.mp3')) {
      final brStr = bitrate > 0 ? '${(bitrate / 1000).round()}kbps' : '320kbps';
      return 'MP3 $brStr CBR';
    }
    if (name.endsWith('.wav')) {
      final rateStr = sampleRate > 0
          ? '${(sampleRate / 1000).toStringAsFixed(1)}kHz'
          : '44.1kHz';
      return 'WAV $rateStr 16-bit';
    }
    if (name.endsWith('.ogg') || name.endsWith('.opus')) {
      return 'OGG Vorbis VBR';
    }
    if (name.endsWith('.m4a') || name.endsWith('.aac')) {
      return 'AAC 256kbps';
    }
    if (track.isLive) {
      return 'ICY STREAM LIVE';
    }
    if (track.isGenerated) {
      return 'SYNTHESIZED PCM';
    }
    return 'HI-RES STEREO';
  }
}
