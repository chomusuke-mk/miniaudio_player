import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_metric_tile.dart';

/// Modal dialog presenting a side-by-side comparison between offline header
/// analysis metadata ([staticMetadata] / [staticAudioInfo]) and live demuxed
/// playback metadata ([dynamicMetadata] / [dynamicAudioInfo]) for [track].
class MetadataInspectorModal extends StatelessWidget {
  /// Track descriptor inspected in this dialog header.
  final AudioTrack track;

  /// Offline metadata extracted prior to playback via `analyzeAudio`, if any.
  final AudioMetadata? staticMetadata;

  /// Real-time metadata emitted from the active native playback stream, if any.
  final AudioMetadata? dynamicMetadata;

  /// Static container and stream properties probed offline, if any.
  final AudioInfo? staticAudioInfo;

  /// Live audio stream properties observed during engine playback, if any.
  final AudioInfo? dynamicAudioInfo;

  /// Creates a [MetadataInspectorModal] comparing static ([staticMetadata],
  /// [staticAudioInfo]) and dynamic ([dynamicMetadata], [dynamicAudioInfo])
  /// inspection data for [track].
  const MetadataInspectorModal({
    super.key,
    required this.track,
    this.staticMetadata,
    this.dynamicMetadata,
    this.staticAudioInfo,
    this.dynamicAudioInfo,
  });

  /// Returns a trimmed tag [value] or `'--'` when `null` or blank.
  String _resolveTag(String? value) {
    if (value == null) return '--';
    final trimmed = value.trim();
    return trimmed.isEmpty ? '--' : trimmed;
  }

  /// Formats [duration] as `MM:SS.t`, returning `'--'` when missing or zero.
  String _formatDuration(Duration? duration) {
    if (duration == null || duration == Duration.zero) return '--';
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (duration.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
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
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isCompact = constraints.maxWidth < 640;

                  final staticCol = _buildMetadataColumn(
                    title: 'STATIC METADATA (audioAnalysis)',
                    subtitle:
                        'Extracted offline via MiniaudioPlayer.analyzeAudio',
                    accentColor: StudioColors.accentCyan,
                    metadata: staticMetadata,
                    info: staticAudioInfo,
                  );

                  final dynamicCol = _buildMetadataColumn(
                    title: 'DYNAMIC METADATA (Playback Engine)',
                    subtitle:
                        'Demuxed in real-time from active playback stream',
                    accentColor: StudioColors.accentEmerald,
                    metadata: dynamicMetadata,
                    info: dynamicAudioInfo,
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

  /// Builds a comparison column titled [title] with [subtitle], styled with
  /// [accentColor], rendering artwork and tag groups from [metadata] and [info].
  Widget _buildMetadataColumn({
    required String title,
    required String subtitle,
    required Color accentColor,
    required AudioMetadata? metadata,
    required AudioInfo? info,
  }) {
    final cover = metadata?.frontCover;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
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
        _buildTagGroup(
          title: 'METADATA TAGS',
          color: accentColor,
          rows: [
            ('Title', _resolveTag(metadata?.title)),
            ('Artist', _resolveTag(metadata?.trackArtist)),
            ('Album', _resolveTag(metadata?.album)),
            ('Album Artist', _resolveTag(metadata?.albumArtist)),
            (
              'Year / Date',
              _resolveTag(
                metadata?.year?.toString() ??
                    metadata?.extended.originalReleaseDate,
              ),
            ),
            ('Genre', _resolveTag(metadata?.genre)),
            (
              'Track #',
              '${metadata?.trackNumber ?? "-"}/${metadata?.trackTotal ?? "-"}',
            ),
            (
              'Disc #',
              '${metadata?.discNumber ?? "-"}/${metadata?.discTotal ?? "-"}',
            ),
            ('RG Track Gain', _resolveTag(metadata?.replayGainTrackGain)),
            ('RG Track Peak', _resolveTag(metadata?.replayGainTrackPeak)),
            ('RG Album Gain', _resolveTag(metadata?.replayGainAlbumGain)),
            ('RG Album Peak', _resolveTag(metadata?.replayGainAlbumPeak)),
            if (metadata?.lyrics != null && metadata!.lyrics!.isNotEmpty)
              (
                'Lyrics',
                '${metadata.lyrics!.substring(0, metadata.lyrics!.length > 40 ? 40 : metadata.lyrics!.length)}...',
              ),
          ],
        ),
        const SizedBox(height: 10),
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

  /// Builds a bordered key-value group box titled [title] with accent [color]
  /// containing key-value [rows].
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
          StudioSubCardHeader(
            icon: Icons.label_outline,
            accentColor: color,
            title: title,
          ),
          ...rows.map(
            (row) => StudioPropertyRow(
              label: row.$1,
              value: row.$2,
              labelWidth: 110,
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview rendering [MetadataInspectorModal] comparing static and dynamic tags.
@StudioPreview(
  name: 'Metadata Inspector Modal',
  group: 'Metadata',
  size: Size(920, 620),
)
Widget metadataInspectorModalPreview() {
  return MetadataInspectorModal(
    track: StudioPreviewData.sampleTrack,
    staticMetadata: StudioPreviewData.sampleMetadata,
    dynamicMetadata: StudioPreviewData.sampleMetadata,
    staticAudioInfo: StudioPreviewData.sampleAudioInfo,
    dynamicAudioInfo: StudioPreviewData.sampleAudioInfo,
  );
}
