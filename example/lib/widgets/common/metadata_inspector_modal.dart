import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';
import 'studio_badge.dart';

/// Modal dialog showing a side-by-side comparison of statically analyzed metadata
/// vs dynamically demuxed runtime metadata from the active playback engine.
class MetadataInspectorModal extends StatelessWidget {
  final AudioTrack track;
  final AudioMetadata? staticMetadata;
  final AudioMetadata? dynamicMetadata;
  final AudioInfo? staticAudioInfo;
  final AudioInfo? dynamicAudioInfo;
  final ReplayGainResult? staticReplayGain;
  final ReplayGainConfig? dynamicReplayGain;

  const MetadataInspectorModal({
    super.key,
    required this.track,
    this.staticMetadata,
    this.dynamicMetadata,
    this.staticAudioInfo,
    this.dynamicAudioInfo,
    this.staticReplayGain,
    this.dynamicReplayGain,
  });

  String _formatDuration(Duration? d) {
    if (d == null || d == Duration.zero) return '--';
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$ms';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF0A0E1A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 750),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Modal Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(
                color: Color(0xFF0F172A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
                border: Border(
                  bottom: BorderSide(color: StudioColors.cardBorder),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.analytics_outlined,
                    color: StudioColors.accentCyan,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'METADATA INSPECTOR',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                            StudioBadge(
                              label: track.title,
                              color: StudioColors.accentCyan,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Comparative Matrix: Offline Header Probing (Static) vs Live Engine Demuxing (Dynamic)',
                          style: TextStyle(
                            fontSize: 10,
                            color: StudioColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    color: StudioColors.textMuted,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // Modal Body: 2 Columns
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 640;

                  final staticCol = _buildMetadataColumn(
                    context: context,
                    title: 'STATIC METADATA (audioAnalysis)',
                    subtitle:
                        'Extracted offline via MiniaudioPlayer.analyzeAudio',
                    accentColor: StudioColors.accentCyan,
                    metadata: staticMetadata,
                    info: staticAudioInfo,
                    gainDb: staticReplayGain?.gainDb != null
                        ? '${staticReplayGain!.gainDb.toStringAsFixed(1)} dB'
                        : staticMetadata?.replayGainTrackGain,
                    peak: staticReplayGain?.peak != null
                        ? staticReplayGain!.peak.toStringAsFixed(3)
                        : staticMetadata?.replayGainTrackPeak,
                  );

                  final dynamicCol = _buildMetadataColumn(
                    context: context,
                    title: 'DYNAMIC METADATA (Playback Engine)',
                    subtitle:
                        'Demuxed in real-time from active playback stream',
                    accentColor: StudioColors.accentEmerald,
                    metadata: dynamicMetadata,
                    info: dynamicAudioInfo,
                    gainDb: dynamicReplayGain?.gainDb != null
                        ? '${dynamicReplayGain!.gainDb.toStringAsFixed(1)} dB'
                        : dynamicMetadata?.replayGainTrackGain,
                    peak: dynamicReplayGain?.peak != null
                        ? dynamicReplayGain!.peak.toStringAsFixed(3)
                        : dynamicMetadata?.replayGainTrackPeak,
                  );

                  if (isCompact) {
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          staticCol,
                          const SizedBox(height: 16),
                          dynamicCol,
                        ],
                      ),
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: staticCol,
                        ),
                      ),
                      Container(width: 1, color: StudioColors.cardBorder),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(12),
                          child: dynamicCol,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetadataColumn({
    required BuildContext context,
    required String title,
    required String subtitle,
    required Color accentColor,
    required AudioMetadata? metadata,
    required AudioInfo? info,
    required String? gainDb,
    required String? peak,
  }) {
    final cover = metadata?.frontCover;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Column Header
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: accentColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: accentColor.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                  color: accentColor,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                subtitle,
                style: const TextStyle(
                  fontSize: 9,
                  color: StudioColors.textMuted,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),

        // Thumbnail / Embedded Artwork Card
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: const Color(0xFF070B14),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: StudioColors.cardBorder),
          ),
          child: cover != null && cover.bytes.isNotEmpty
              ? Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.memory(
                        cover.bytes,
                        width: 90,
                        height: 90,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            cover.pictureType.name.toUpperCase(),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                              color: accentColor,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'MIME: ${cover.mimeType?.name ?? "image/jpeg"}',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Size: ${(cover.bytes.lengthInBytes / 1024).toStringAsFixed(1)} KB',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.textSecondary,
                            ),
                          ),
                          if (cover.description != null &&
                              cover.description!.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Desc: ${cover.description}',
                              style: const TextStyle(
                                fontSize: 9,
                                color: StudioColors.textMuted,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                )
              : Container(
                  height: 64,
                  alignment: Alignment.center,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(
                        Icons.image_not_supported_outlined,
                        size: 18,
                        color: StudioColors.textMuted,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'No embedded cover art detected',
                        style: TextStyle(
                          fontSize: 10,
                          color: StudioColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
        const SizedBox(height: 10),

        // Core Tags
        _buildTagGroup(
          title: 'CORE METADATA TAGS',
          color: accentColor,
          rows: [
            ('Title', metadata?.title ?? '--'),
            ('Artist', metadata?.trackArtist ?? '--'),
            ('Album', metadata?.album ?? '--'),
            ('Album Artist', metadata?.albumArtist ?? '--'),
            (
              'Year / Date',
              metadata?.year?.toString() ??
                  metadata?.extended.originalReleaseDate ??
                  '--',
            ),
            ('Genre', metadata?.genre ?? '--'),
            (
              'Track #',
              '${metadata?.trackNumber ?? "-"}/${metadata?.trackTotal ?? "-"}',
            ),
            (
              'Disc #',
              '${metadata?.discNumber ?? "-"}/${metadata?.discTotal ?? "-"}',
            ),
            if (metadata?.lyrics != null && metadata!.lyrics!.isNotEmpty)
              (
                'Lyrics',
                '${metadata.lyrics!.substring(0, metadata.lyrics!.length > 40 ? 40 : metadata.lyrics!.length)}...',
              ),
          ],
        ),
        const SizedBox(height: 10),

        // Audio & Container Properties
        _buildTagGroup(
          title: 'AUDIO STREAM PROPERTIES',
          color: accentColor,
          rows: [
            ('Container Format', info?.containerFormat ?? info?.format ?? '--'),
            ('Audio Codec', info?.codec ?? '--'),
            (
              'Sample Rate',
              info?.sampleRate != null && info!.sampleRate > 0
                  ? '${info.sampleRate} Hz'
                  : '--',
            ),
            (
              'Channels',
              info?.channels != null && info!.channels > 0
                  ? '${info.channels} ch'
                  : '--',
            ),
            (
              'Bit Depth',
              info?.bitsPerSample != null && info!.bitsPerSample! > 0
                  ? '${info.bitsPerSample}-bit'
                  : '--',
            ),
            (
              'Bitrate',
              info?.bitrate != null && info!.bitrate > 0
                  ? '${(info.bitrate / 1000).round()} kbps'
                  : '--',
            ),
            ('Duration', _formatDuration(info?.duration)),
            (
              'Lossless',
              info?.lossless == true
                  ? 'Lossless (Bit-perfect)'
                  : 'Lossy / Unknown',
            ),
          ],
        ),
        const SizedBox(height: 10),

        // Loudness & ReplayGain Normalization
        _buildTagGroup(
          title: 'REPLAYGAIN & LOUDNESS TAGS',
          color: accentColor,
          rows: [
            ('Track Gain', gainDb ?? metadata?.replayGainTrackGain ?? '--'),
            ('Track Peak', peak ?? metadata?.replayGainTrackPeak ?? '--'),
            ('Album Gain', metadata?.replayGainAlbumGain ?? '--'),
            ('Album Peak', metadata?.replayGainAlbumPeak ?? '--'),
          ],
        ),
        const SizedBox(height: 10),

        // Extended Information
        _buildTagGroup(
          title: 'EXTENDED TAGS & CREDITS',
          color: accentColor,
          rows: [
            ('ISRC', metadata?.extended.isrc ?? '--'),
            ('Record Label', metadata?.extended.label ?? '--'),
            ('Copyright', metadata?.extended.copyrightMessage ?? '--'),
            ('MusicBrainz ID', metadata?.extended.musicBrainzTrackId ?? '--'),
            ('Chapters', '${metadata?.chapters.length ?? 0} chapters'),
          ],
        ),
      ],
    );
  }

  Widget _buildTagGroup({
    required String title,
    required Color color,
    required List<(String, String)> rows,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1424),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(5),
              ),
              border: Border(
                bottom: BorderSide(
                  color: StudioColors.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 0.5,
              ),
            ),
          ),
          ...rows.map((r) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 110,
                    child: Text(
                      r.$1,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: StudioColors.textMuted,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      r.$2,
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: Colors.white,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }
}
