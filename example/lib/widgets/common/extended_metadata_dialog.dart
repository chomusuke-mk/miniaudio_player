import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../theme/studio_colors.dart';
import 'studio_badge.dart';

/// Modal dialog presenting complete extended metadata tags, credits,
/// identifiers, lyrics, chapters, and custom tags.
class ExtendedMetadataDialog extends StatelessWidget {
  final AudioMetadata? metadata;
  final String trackTitle;

  const ExtendedMetadataDialog({
    super.key,
    required this.metadata,
    required this.trackTitle,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$ms';
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

            // Modal Body
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

                          // Chapters
                          if (chapters.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildChaptersSection(chapters),
                          ],

                          // Lyrics
                          if (lyrics != null && lyrics.trim().isNotEmpty) ...[
                            const SizedBox(height: 12),
                            _buildLyricsSection(lyrics),
                          ],

                          // Custom Tags
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

  Widget _buildSection({
    required String title,
    required IconData icon,
    required Color color,
    required List<(String, String?)> rows,
  }) {
    final activeRows = rows
        .where((r) => r.$2 != null && r.$2!.trim().isNotEmpty)
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1424),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              border: Border(
                bottom: BorderSide(
                  color: StudioColors.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: color,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '${activeRows.length} active',
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: StudioColors.textMuted,
                  ),
                ),
              ],
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
            ...activeRows.map((r) {
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
                        r.$1,
                        style: const TextStyle(
                          fontSize: 9.5,
                          color: StudioColors.textMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SelectableText(
                        r.$2!,
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1424),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              border: Border(
                bottom: BorderSide(
                  color: StudioColors.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.bookmark_outline,
                  size: 14,
                  color: StudioColors.accentCyan,
                ),
                const SizedBox(width: 6),
                const Text(
                  'EMBEDDED CHAPTERS',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.accentCyan,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '${chapters.length} chapters',
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: StudioColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.all(8),
            itemCount: chapters.length,
            separatorBuilder: (context, index) =>
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1424),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              border: Border(
                bottom: BorderSide(
                  color: StudioColors.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.lyrics_outlined,
                  size: 14,
                  color: StudioColors.accentEmerald,
                ),
                SizedBox(width: 6),
                Text(
                  'SYNCHRONIZED / UNSYNCHRONIZED LYRICS',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.accentEmerald,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
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
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF0E1424),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(7),
              ),
              border: Border(
                bottom: BorderSide(
                  color: StudioColors.cardBorder.withValues(alpha: 0.6),
                ),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.code,
                  size: 14,
                  color: StudioColors.accentAmber,
                ),
                const SizedBox(width: 6),
                const Text(
                  'CUSTOM USER TAGS (TXXX / VORBIS COMMENTS)',
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    color: StudioColors.accentAmber,
                    letterSpacing: 0.5,
                  ),
                ),
                const Spacer(),
                Text(
                  '${customTags.length} tags',
                  style: const TextStyle(
                    fontSize: 8.5,
                    color: StudioColors.textMuted,
                  ),
                ),
              ],
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
