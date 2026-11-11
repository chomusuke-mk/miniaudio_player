import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../theme/studio_colors.dart';
import 'studio_badge.dart';

/// Modal dialog displaying all embedded pictures and artwork thumbnails
/// extracted from an audio container.
class ThumbnailsViewerDialog extends StatelessWidget {
  final List<AudioPicture> pictures;
  final String trackTitle;

  const ThumbnailsViewerDialog({
    super.key,
    required this.pictures,
    required this.trackTitle,
  });

  String _formatPictureType(PictureType type) {
    return switch (type) {
      PictureType.coverFront => 'Front Cover',
      PictureType.coverBack => 'Back Cover',
      PictureType.leaflet => 'Leaflet Page',
      PictureType.media => 'Media Label',
      PictureType.leadArtist => 'Lead Artist',
      PictureType.artist => 'Artist / Performer',
      PictureType.conductor => 'Conductor',
      PictureType.band => 'Band / Orchestra',
      PictureType.composer => 'Composer',
      PictureType.lyricist => 'Lyricist / Text Writer',
      PictureType.recordingLocation => 'Recording Location',
      PictureType.duringRecording => 'During Recording',
      PictureType.duringPerformance => 'During Performance',
      PictureType.screenCapture => 'Screen Capture',
      PictureType.illustration => 'Illustration',
      PictureType.bandLogo => 'Band / Artist Logo',
      PictureType.publisherLogo => 'Publisher / Studio Logo',
      PictureType.icon => 'File Icon',
      PictureType.otherIcon => 'Other Icon',
      PictureType.brightFish => 'Bright Fish',
      PictureType.other => 'Other Picture',
    };
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
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Dialog Header
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
                    Icons.photo_library_outlined,
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
                              'EMBEDDED THUMBNAILS',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.5,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(width: 8),
                            StudioBadge(
                              label:
                                  '${pictures.length} ${pictures.length == 1 ? "IMAGE" : "IMAGES"}',
                              color: StudioColors.accentCyan,
                            ),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Artwork extracted from container for "$trackTitle"',
                          style: const TextStyle(
                            fontSize: 10,
                            color: StudioColors.textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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

            // Dialog Content
            Expanded(
              child: pictures.isEmpty
                  ? const Center(
                      child: Text(
                        'No embedded pictures detected in this audio file.',
                        style: TextStyle(
                          fontSize: 11,
                          color: StudioColors.textMuted,
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: pictures.length,
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 16),
                      itemBuilder: (context, index) {
                        final picture = pictures[index];
                        final kb = (picture.bytes.lengthInBytes / 1024)
                            .toStringAsFixed(1);
                        final typeLabel = _formatPictureType(
                          picture.pictureType,
                        );

                        return Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF070B14),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: StudioColors.cardBorder,
                              width: 0.8,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  width: 110,
                                  height: 110,
                                  color: const Color(0xFF0C101D),
                                  child: Image.memory(
                                    picture.bytes,
                                    fit: BoxFit.cover,
                                    errorBuilder:
                                        (context, error, stackTrace) =>
                                            const Center(
                                              child: Icon(
                                                Icons.broken_image_outlined,
                                                size: 24,
                                                color: StudioColors.textMuted,
                                              ),
                                            ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: StudioColors.accentCyan
                                                .withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(
                                              4,
                                            ),
                                            border: Border.all(
                                              color: StudioColors.accentCyan
                                                  .withValues(alpha: 0.3),
                                            ),
                                          ),
                                          child: Text(
                                            typeLabel.toUpperCase(),
                                            style: const TextStyle(
                                              fontSize: 9.5,
                                              fontWeight: FontWeight.bold,
                                              color: StudioColors.accentCyan,
                                              letterSpacing: 0.4,
                                            ),
                                          ),
                                        ),
                                        const Spacer(),
                                        Text(
                                          '#${index + 1}',
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.w700,
                                            color: StudioColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    _buildMetaRow(
                                      'MIME Type',
                                      picture.mimeType?.name ?? 'image/jpeg',
                                    ),
                                    const SizedBox(height: 4),
                                    _buildMetaRow(
                                      'Payload Size',
                                      '$kb KB (${picture.bytes.lengthInBytes} bytes)',
                                    ),
                                    if (picture.description != null &&
                                        picture.description!.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      _buildMetaRow(
                                        'Description',
                                        picture.description!,
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetaRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 9.5,
              color: StudioColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              fontSize: 9.5,
              color: Colors.white,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ],
    );
  }
}
