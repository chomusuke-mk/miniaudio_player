import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_metric_tile.dart';
import '../../metadata/widgets/extended_metadata_dialog.dart';
import '../../metadata/widgets/thumbnails_viewer_dialog.dart';

/// Pure sub-section presenting parsed metadata tags, embedded artwork previews,
/// and interactive modals for extended metadata and cover art inspection.
class AnalyzerMetadataSection extends StatelessWidget {
  /// Extracted container metadata payload, or `null` when unavailable.
  final AudioMetadata? metadata;

  /// Associated track title forwarded into detail modal titles.
  final String trackTitle;

  /// Whether acoustic analysis is currently running.
  final bool isLoading;

  /// Creates an [AnalyzerMetadataSection] displaying [metadata] for
  /// [trackTitle] with loading state [isLoading].
  const AnalyzerMetadataSection({
    super.key,
    required this.metadata,
    required this.trackTitle,
    this.isLoading = false,
  });

  /// Returns `'loading...'` while [isLoading], trimmed [value] if populated,
  /// or `'--'` otherwise.
  String _resolveText(String? value, bool isLoading) {
    if (isLoading) return 'loading...';
    if (value == null || value.trim().isEmpty) return '--';
    return value;
  }

  /// Counts populated extended tag credits, MusicBrainz IDs, BPM, lyrics,
  /// chapters, and custom user tags inside [meta].
  int _countExtendedFields(AudioMetadata? meta) {
    if (meta == null) return 0;
    int count = 0;
    final ext = meta.extended;
    final fields = [
      ext.isrc,
      ext.barcode,
      ext.catalogNumber,
      ext.label,
      ext.publisher,
      ext.musicBrainzTrackId,
      ext.musicBrainzRecordingId,
      ext.musicBrainzReleaseId,
      ext.musicBrainzArtistId,
      ext.musicBrainzReleaseArtistId,
      ext.musicBrainzWorkId,
      ext.musicBrainzReleaseType,
      ext.acoustId,
      ext.composer,
      ext.lyricist,
      ext.producer,
      ext.engineer,
      ext.arranger,
      ext.conductor,
      ext.performer,
      ext.remixer,
      ext.mixDj,
      ext.director,
      ext.releaseDate,
      ext.originalReleaseDate,
      ext.recordingDate,
      ext.initialKey,
      ext.mood,
      ext.color,
      ext.copyrightMessage,
      ext.license,
      ext.copyrightUrl,
      ext.commercialInformationUrl,
    ];
    for (final field in fields) {
      if (field != null && field.trim().isNotEmpty) count++;
    }
    if (meta.bpm != null) count++;
    if (meta.lyrics != null && meta.lyrics!.trim().isNotEmpty) count++;
    count += meta.chapters.length;
    count += meta.customTags.length;
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final pictures = metadata?.pictures ?? const <AudioPicture>[];
    final extendedCount = _countExtendedFields(metadata);

    final rows = <(String, String)>[
      ('Title', _resolveText(metadata?.title, isLoading)),
      ('Artist', _resolveText(metadata?.trackArtist, isLoading)),
      ('Album', _resolveText(metadata?.album, isLoading)),
      (
        'Year / Date',
        _resolveText(
          metadata?.year?.toString() ?? metadata?.extended.originalReleaseDate,
          isLoading,
        ),
      ),
      ('Genre', _resolveText(metadata?.genre, isLoading)),
      (
        'Track #',
        isLoading
            ? 'loading...'
            : (metadata?.trackNumber != null
                  ? '${metadata!.trackNumber}/${metadata!.trackTotal ?? "-"}'
                  : '--'),
      ),
      (
        'RG Track Gain',
        _resolveText(metadata?.replayGainTrackGain, isLoading),
      ),
      (
        'RG Track Peak',
        _resolveText(metadata?.replayGainTrackPeak, isLoading),
      ),
      (
        'RG Album Gain',
        _resolveText(metadata?.replayGainAlbumGain, isLoading),
      ),
      (
        'RG Album Peak',
        _resolveText(metadata?.replayGainAlbumPeak, isLoading),
      ),
      (
        'BPM',
        isLoading
            ? 'loading...'
            : (metadata?.bpm != null
                  ? metadata!.bpm!.toStringAsFixed(1)
                  : '--'),
      ),
      (
        'Chapters',
        isLoading
            ? 'loading...'
            : (metadata != null && metadata!.chapters.isNotEmpty
                  ? '${metadata!.chapters.length}'
                  : '--'),
      ),
      (
        'Lyrics',
        isLoading
            ? 'loading...'
            : (metadata?.lyrics != null && metadata!.lyrics!.trim().isNotEmpty
                  ? '${metadata!.lyrics!.trim().length} chars'
                  : '--'),
      ),
    ];

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
            icon: Icons.library_music_outlined,
            accentColor: StudioColors.accentPurple,
            title: 'METADATA',
            subtitle:
                'Embedded tags, album credits, multi-image artwork thumbnails, and extended studio credits.',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                ...rows.map(
                  (row) => StudioPropertyRow(
                    label: row.$1,
                    value: row.$2,
                    isLoading: isLoading,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 86,
                        child: Text(
                          'Thumbnails',
                          style: TextStyle(
                            fontSize: 9,
                            color: StudioColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: isLoading
                            ? const Text(
                                'loading...',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              )
                            : (pictures.isEmpty
                                  ? const Text(
                                      '--',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.centerLeft,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: InkWell(
                                          onTap: () {
                                            showDialog<void>(
                                              context: context,
                                              builder: (_) =>
                                                  ThumbnailsViewerDialog(
                                                    pictures: pictures,
                                                    trackTitle: trackTitle,
                                                  ),
                                            );
                                          },
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ...pictures.take(3).map((pic) {
                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                        right: 4,
                                                      ),
                                                  child: ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                    child: Container(
                                                      width: 20,
                                                      height: 20,
                                                      color: const Color(
                                                        0xFF0E1424,
                                                      ),
                                                      child: Image.memory(
                                                        pic.bytes,
                                                        fit: BoxFit.cover,
                                                        errorBuilder:
                                                            (
                                                              context,
                                                              error,
                                                              stackTrace,
                                                            ) => const Icon(
                                                              Icons.image,
                                                              size: 14,
                                                              color: StudioColors
                                                                  .textMuted,
                                                            ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              }),
                                              if (pictures.length > 3)
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 4,
                                                        vertical: 1.5,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        StudioColors.cardBorder,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                  ),
                                                  child: Text(
                                                    '+${pictures.length - 3}...',
                                                    style: const TextStyle(
                                                      fontSize: 7.5,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                ),
                                              const SizedBox(width: 4),
                                              const Icon(
                                                Icons.open_in_new,
                                                size: 11,
                                                color: StudioColors.accentCyan,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    )),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 3,
                  ),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 86,
                        child: Text(
                          'Extended Tags',
                          style: TextStyle(
                            fontSize: 9,
                            color: StudioColors.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      Expanded(
                        child: isLoading
                            ? const Text(
                                'loading...',
                                style: TextStyle(
                                  fontSize: 9,
                                  color: Color(0xFF64748B),
                                  fontFamily: 'monospace',
                                ),
                              )
                            : (extendedCount == 0
                                  ? const Text(
                                      '--',
                                      style: TextStyle(
                                        fontSize: 9,
                                        color: StudioColors.textMuted,
                                        fontFamily: 'monospace',
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.centerLeft,
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.centerLeft,
                                        child: InkWell(
                                          onTap: () {
                                            showDialog<void>(
                                              context: context,
                                              builder: (_) =>
                                                  ExtendedMetadataDialog(
                                                    metadata: metadata,
                                                    trackTitle: trackTitle,
                                                  ),
                                            );
                                          },
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: StudioColors.accentPurple
                                                  .withValues(alpha: 0.15),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                color: StudioColors.accentPurple
                                                    .withValues(alpha: 0.4),
                                                width: 0.8,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  Icons.open_in_new,
                                                  size: 10,
                                                  color:
                                                      StudioColors.accentPurple,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  'VIEW EXTENDED ($extendedCount)',
                                                  style: const TextStyle(
                                                    fontSize: 8.5,
                                                    fontWeight: FontWeight.bold,
                                                    color: StudioColors
                                                        .accentPurple,
                                                    letterSpacing: 0.3,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    )),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Preview rendering [AnalyzerMetadataSection] with populated studio metadata.
@StudioPreview(
  name: 'Analyzer Metadata Section',
  group: 'Analyzer',
  size: Size(280, 420),
)
Widget analyzerMetadataSectionPreview() {
  return AnalyzerMetadataSection(
    metadata: StudioPreviewData.sampleMetadata,
    trackTitle: StudioPreviewData.sampleTrack.title,
  );
}
