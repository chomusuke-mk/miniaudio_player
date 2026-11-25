import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';

/// Pure presentational reorderable queue row rendering drag handle, index,
/// cover artwork or icon, resolved title/artist, engine ID badge, and source pill.
class QueueTrackTile extends StatelessWidget {
  /// Track descriptor rendered by this row.
  final AudioTrack track;

  /// Zero-based position inside the visible queue list.
  final int index;

  /// Whether this queue item is the actively selected/playing entry.
  final bool isPlaying;

  /// Preferred track title (preferring live/static metadata over catalog title).
  final String displayTitle;

  /// Preferred artist line (preferring live/static metadata over fallback).
  final String displayArtist;

  /// Optional embedded cover image rendered as the row thumbnail.
  final AudioPicture? frontCover;

  /// Native engine queue identifier shown when assigned.
  final int? sourceId;

  /// Invoked when the user taps the row to activate playback.
  final VoidCallback onTap;

  /// Creates a [QueueTrackTile] at queue [index] for [track], showing
  /// [displayTitle], [displayArtist], optional [frontCover] and [sourceId],
  /// active [isPlaying] styling, and [onTap] handler.
  const QueueTrackTile({
    super.key,
    required this.track,
    required this.index,
    required this.isPlaying,
    required this.displayTitle,
    required this.displayArtist,
    this.frontCover,
    this.sourceId,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Material(
        color: isPlaying ? const Color(0xFF152238) : const Color(0xFF0C1222),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
          side: BorderSide(
            color: isPlaying ? StudioColors.accentCyan : StudioColors.cardBorder,
            width: isPlaying ? 1.2 : 0.8,
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 8,
              vertical: 2,
            ),
            leading: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  index: index,
                  child: const MouseRegion(
                    cursor: SystemMouseCursors.grab,
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 4,
                      ),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 16,
                        color: StudioColors.textMuted,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${index + 1}'.padLeft(2, '0'),
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: isPlaying
                        ? StudioColors.accentCyan
                        : StudioColors.textMuted,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080D1A),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: isPlaying
                          ? StudioColors.accentCyan.withValues(alpha: 0.5)
                          : StudioColors.cardBorder,
                      width: 0.8,
                    ),
                  ),
                  child: frontCover != null && frontCover!.bytes.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Image.memory(
                            frontCover!.bytes,
                            width: 32,
                            height: 32,
                            fit: BoxFit.cover,
                          ),
                        )
                      : Icon(
                          isPlaying ? Icons.equalizer : track.icon,
                          size: 16,
                          color: isPlaying
                              ? StudioColors.accentCyan
                              : track.iconColor,
                        ),
                ),
              ],
            ),
            title: Text(
              displayTitle,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isPlaying ? FontWeight.bold : FontWeight.w500,
                color: isPlaying ? StudioColors.accentCyan : Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              displayArtist,
              style: const TextStyle(
                fontSize: 9,
                color: StudioColors.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 4,
              children: [
                if (sourceId != null)
                  StudioBadge(
                    label: 'ID #$sourceId',
                    color: StudioColors.accentPurple,
                  ),
                StudioBadge(
                  label: track.resourceBadge,
                  color: track.iconColor,
                ),
              ],
            ),
            onTap: onTap,
          ),
        ),
      ),
    );
  }
}

/// Preview rendering playing and queued [QueueTrackTile] variants.
@StudioPreview(
  name: 'Queue Track Tiles',
  group: 'Queue',
  size: Size(520, 150),
)
Widget queueTrackTilePreview() {
  return Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      QueueTrackTile(
        track: StudioPreviewData.sampleTrack,
        index: 0,
        isPlaying: true,
        displayTitle: StudioPreviewData.sampleTrack.title,
        displayArtist: StudioPreviewData.sampleTrack.artist ?? 'Audio Track',
        sourceId: 1,
        onTap: StudioPreviewData.noopVoid,
      ),
      QueueTrackTile(
        track: StudioPreviewData.sampleRemoteTrack,
        index: 1,
        isPlaying: false,
        displayTitle: StudioPreviewData.sampleRemoteTrack.title,
        displayArtist:
            StudioPreviewData.sampleRemoteTrack.artist ?? 'Audio Track',
        sourceId: 2,
        onTap: StudioPreviewData.noopVoid,
      ),
    ],
  );
}
