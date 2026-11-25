import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_metric_tile.dart';

/// Modal dialog presenting extended container metadata tags, MusicBrainz /
/// AcoustID identifiers, production credits, lyrics, chapters, and custom tags.
class ExtendedMetadataDialog extends StatelessWidget {
  /// Parsed metadata payload to inspect, or `null` when unavailable.
  final AudioMetadata? metadata;

  /// Display title of the inspected audio track shown in the header badge.
  final String trackTitle;

  /// Creates an [ExtendedMetadataDialog] displaying extended fields from
  /// [metadata] for [trackTitle].
  const ExtendedMetadataDialog({
    super.key,
    required this.metadata,
    required this.trackTitle,
  });

  /// Formats [duration] as `MM:SS.t` for chapter timestamp badges.
  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (duration.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  @override
  Widget build(BuildContext context) {
    final ext = metadata?.extended;
    final chapters = metadata?.chapters ?? const [];
    final customTags = metadata?.customTags ?? const {};
    final lyrics = metadata?.lyrics;

    return Dialog(
      backgroundColor: const Color(0xFF0A0E1A),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: StudioColors.cardBorder, width: 1.2),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
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
                    Icons.assignment_outlined,
                    color: StudioColors.accentPurple,
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
                              'EXTENDED METADATA TAGS',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                            StudioBadge(
                              label: trackTitle,
                              color: StudioColors.accentPurple,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Full acoustic credits, identifiers, licensing, chapters, and container tags',
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
              child: metadata == null
                  ? const Center(
                      child: Text(
                        'No metadata available for this track.',
                        style: TextStyle(
                          fontSize: 11,
                          color: StudioColors.textMuted,
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildSection(
                            title: 'IDENTIFIERS & PUBLISHING',
                            icon: Icons.fingerprint,
                            color: StudioColors.accentCyan,
                            rows: [
                              ('ISRC Code', ext?.isrc),
                              ('Barcode (UPC/EAN)', ext?.barcode),
                              ('Catalog Number', ext?.catalogNumber),
                              ('Record Label', ext?.label),
                              ('Publisher', ext?.publisher),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildSection(
                            title: 'MUSICBRAINZ & ACOUSTID',
                            icon: Icons.tag,
                            color: StudioColors.accentPurple,
                            rows: [
                              ('Track ID', ext?.musicBrainzTrackId),
                              ('Recording ID', ext?.musicBrainzRecordingId),
                              ('Release ID', ext?.musicBrainzReleaseId),
                              ('Artist ID', ext?.musicBrainzArtistId),
                              (
                                'Release Artist ID',
                                ext?.musicBrainzReleaseArtistId,
                              ),
                              ('Work ID', ext?.musicBrainzWorkId),
                              ('Release Type', ext?.musicBrainzReleaseType),
                              ('AcoustID', ext?.acoustId),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildSection(
                            title: 'PRODUCTION & PERSONNEL CREDITS',
                            icon: Icons.people_outline,
                            color: StudioColors.accentEmerald,
                            rows: [
                              ('Composer', ext?.composer),
                              ('Lyricist', ext?.lyricist),
                              ('Producer', ext?.producer),
                              ('Engineer', ext?.engineer),
                              ('Arranger', ext?.arranger),
                              ('Conductor', ext?.conductor),
                              ('Performer', ext?.performer),
                              ('Remixer', ext?.remixer),
                              ('Mix DJ', ext?.mixDj),
                              ('Director', ext?.director),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildSection(
                            title: 'DATES, HARMONIC & MOOD',
                            icon: Icons.calendar_today_outlined,
                            color: StudioColors.accentAmber,
                            rows: [
                              ('Release Date', ext?.releaseDate),
                              (
                                'Original Release Date',
                                ext?.originalReleaseDate,
                              ),
                              ('Recording Date', ext?.recordingDate),
                              ('Initial Key', ext?.initialKey),
                              (
                                'BPM (Tempo)',
                                metadata?.bpm != null
                                    ? '${metadata!.bpm} BPM'
                                    : null,
                              ),
                              ('Mood / Color', ext?.mood ?? ext?.color),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildSection(
                            title: 'RIGHTS & LICENSING',
                            icon: Icons.verified_user_outlined,
                            color: const Color(0xFF38BDF8),
                            rows: [
                              ('Copyright Message', ext?.copyrightMessage),
                              ('License', ext?.license),
                              ('Copyright URL', ext?.copyrightUrl),
                              (
                                'Commercial Info URL',
                                ext?.commercialInformationUrl,
                              ),
                            ],
                          ),
                          if (chapters.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildChaptersSection(chapters),
                          ],
                          if (lyrics != null && lyrics.trim().isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildLyricsSection(lyrics),
                          ],
                          if (customTags.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildCustomTagsSection(customTags),
                          ],
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a tag group titled [title] with [icon] tinted by [color], showing
  /// only populated non-empty entries from [rows].
  Widget _buildSection({
    required String title,
    required IconData icon,
    required Color color,
    required List<(String, String?)> rows,
  }) {
    final activeRows = rows
        .where((row) => row.$2 != null && row.$2!.trim().isNotEmpty)
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSubCardHeader(
            icon: icon,
            accentColor: color,
            title: title,
            trailing: Text(
              '${activeRows.length} active',
              style: const TextStyle(
                fontSize: 8.5,
                color: StudioColors.textMuted,
              ),
            ),
          ),
          if (activeRows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                'None populated in container',
                style: TextStyle(
                  fontSize: 9.5,
                  color: StudioColors.textMuted,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...activeRows.map((row) {
              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 140,
                      child: Text(
                        row.$1,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: StudioColors.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        row.$2!,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: Colors.white,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  /// Builds the chapter index list for embedded [chapters].
  Widget _buildChaptersSection(List<AudioChapter> chapters) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSubCardHeader(
            icon: Icons.bookmark_outline,
            accentColor: StudioColors.accentCyan,
            title: 'EMBEDDED CHAPTERS',
            trailing: Text(
              '${chapters.length} chapters',
              style: const TextStyle(
                fontSize: 8.5,
                color: StudioColors.textMuted,
              ),
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(8),
            itemCount: chapters.length,
            separatorBuilder: (_, _) =>
                const Divider(height: 8, color: StudioColors.cardBorder),
            itemBuilder: (context, idx) {
              final ch = chapters[idx];
              final startStr = _formatDuration(ch.startTime);
              final endStr = _formatDuration(ch.endTime);
              return Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: StudioColors.accentCyan.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '#${idx + 1}',
                      style: const TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: StudioColors.accentCyan,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '[$startStr - $endStr]',
                    style: const TextStyle(
                      fontSize: 9,
                      color: StudioColors.textMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      ch.title.isNotEmpty ? ch.title : 'Chapter ${idx + 1}',
                      style: const TextStyle(
                        fontSize: 9.5,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Builds the scrollable monospace container rendering [lyrics].
  Widget _buildLyricsSection(String lyrics) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StudioSubCardHeader(
            icon: Icons.lyrics_outlined,
            accentColor: StudioColors.accentEmerald,
            title: 'SYNCHRONIZED / UNSYNCHRONIZED LYRICS',
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF05070D),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: StudioColors.cardBorder.withValues(alpha: 0.4),
                ),
              ),
              child: SelectableText(
                lyrics,
                style: const TextStyle(
                  fontSize: 9.5,
                  color: Color(0xFFE2E8F0),
                  height: 1.45,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the custom `TXXX` / Vorbis comment section for [customTags].
  Widget _buildCustomTagsSection(Map<String, String> customTags) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF070B14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 0.8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          StudioSubCardHeader(
            icon: Icons.code,
            accentColor: StudioColors.accentAmber,
            title: 'CUSTOM USER TAGS (TXXX / VORBIS COMMENTS)',
            trailing: Text(
              '${customTags.length} tags',
              style: const TextStyle(
                fontSize: 8.5,
                color: StudioColors.textMuted,
              ),
            ),
          ),
          ...customTags.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 140,
                    child: Text(
                      entry.key,
                      style: const TextStyle(
                        fontSize: 9,
                        color: StudioColors.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 9,
                        color: Colors.white,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// Preview rendering [ExtendedMetadataDialog] with sample credits and chapters.
@StudioPreview(
  name: 'Extended Metadata Dialog',
  group: 'Metadata',
  size: Size(760, 620),
)
Widget extendedMetadataDialogPreview() {
  return ExtendedMetadataDialog(
    metadata: StudioPreviewData.sampleMetadata,
    trackTitle: StudioPreviewData.sampleTrack.title,
  );
}
