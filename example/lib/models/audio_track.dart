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

  bool get isLive => source is LiveStreamAudioSource;

  bool get canAnalyze {
    if (isLive || source is LiveStreamAudioSource) return false;
    if (source is NetworkAudioSource) return false;
    final uri = source.uri;
    if (uri != null) {
      final scheme = uri.scheme.toLowerCase();
      if (scheme == 'icy' || scheme == 'http' || scheme == 'https') return false;
    }
    return source is AssetAudioSource ||
        source is MemoryAudioSource ||
        source is FileAudioSource ||
        (uri?.isScheme('file') ?? false);
  }

  String get resourceBadge {
    if (isGenerated) return 'DATA URI';
    if (source is ResolvingAudioSource) return 'RESOLVER';
    if (source is LiveStreamAudioSource) return 'LIVE STREAM';
    if (source is NetworkAudioSource) return 'NETWORK';
    if (source is MemoryAudioSource) return 'MEMORY';
    if (source is AssetAudioSource) return 'ASSET';
    if (source is FileAudioSource) return 'FILE';
    return 'SOURCE';
  }

  String get displayType {
    if (isGenerated) return 'data: URI';
    if (source is ResolvingAudioSource) return 'content / fd';
    if (source is AssetAudioSource) return 'asset://';
    if (source is MemoryAudioSource) return 'Memoria RAM';
    if (source is LiveStreamAudioSource) return 'icy:// (Live)';
    if (source is NetworkAudioSource) return 'https://';
    if (source is FileAudioSource) return 'file://';
    return 'URI';
  }

  IconData get icon {
    if (isGenerated) return Icons.graphic_eq;
    if (source is ResolvingAudioSource) return Icons.alt_route;
    if (source is LiveStreamAudioSource) return Icons.radio;
    if (source is NetworkAudioSource) return Icons.cloud_outlined;
    if (source is MemoryAudioSource) return Icons.memory;
    if (source is AssetAudioSource) return Icons.audiotrack;
    return Icons.insert_drive_file_outlined;
  }

  Color get iconColor {
    if (isGenerated) return Colors.amberAccent;
    if (source is ResolvingAudioSource) return Colors.orangeAccent;
    if (source is LiveStreamAudioSource) return Colors.redAccent;
    if (source is NetworkAudioSource) return Colors.lightBlueAccent;
    if (source is MemoryAudioSource) return Colors.purpleAccent;
    if (source is AssetAudioSource) return Colors.tealAccent;
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
  static String deduceFormatBadge(AudioTrack? track, {int sampleRate = 0, int channels = 0, int bitrate = 0}) {
    if (track == null) return 'AUDIO ENGINE';
    final name = (track.source.uri?.path ?? track.title).toLowerCase();

    if (name.endsWith('.flac')) {
      final rateStr = sampleRate > 0 ? '${(sampleRate / 1000).toStringAsFixed(0)}kHz' : '96kHz';
      return 'FLAC $rateStr / 24-bit';
    }
    if (name.endsWith('.mp3')) {
      final brStr = bitrate > 0 ? '${(bitrate / 1000).round()}kbps' : '320kbps';
      return 'MP3 $brStr CBR';
    }
    if (name.endsWith('.wav')) {
      final rateStr = sampleRate > 0 ? '${(sampleRate / 1000).toStringAsFixed(1)}kHz' : '44.1kHz';
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
      return 'PCM SINTETIZADO';
    }
    return 'HI-RES STEREO';
  }
}
