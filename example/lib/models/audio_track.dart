import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

class AudioTrack {
  final String id;
  final String title;
  final AudioSource source;
  final bool isGenerated;
  final String? artist;
  final String? album;
  final double? replayGainDb;
  final double? replayPeak;

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

  String get _sourceString => source.uri ?? '';

  bool get _isNetwork {
    final s = _sourceString.toLowerCase();
    return s.startsWith('http://') ||
        s.startsWith('https://') ||
        s.startsWith('icy://');
  }

  bool get isHlsVod =>
      _isNetwork && _sourceString.toLowerCase().contains('.m3u8');

  bool get isLive {
    final s = _sourceString.toLowerCase();
    return _isNetwork &&
        (s.contains('/live') ||
            s.contains('icecast') ||
            s.startsWith('icy://'));
  }

  bool get canAnalyze => true;

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

abstract final class TrackFormatInfo {
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
