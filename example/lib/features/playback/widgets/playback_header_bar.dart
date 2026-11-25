import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/preview/studio_preview.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/studio_badge.dart';

/// Pure presentational banner displaying the active track artwork or icon,
/// resolved metadata title/artist, live stream buffer window badge, source type
/// pill, and optional metadata comparison trigger.
class PlaybackHeaderBar extends StatelessWidget {
  /// Currently selected or active [AudioTrack], or `null` when idle.
  final AudioTrack? activeTrack;

  /// Resolved title text (preferring dynamic/static metadata over fallback).
  final String displayTitle;

  /// Resolved artist subtitle text.
  final String displayArtist;

  /// Optional embedded album artwork image extracted for the track.
  final AudioPicture? frontCover;

  /// Current decoder ring buffer coverage and buffering status.
  final Buffer buffer;

  /// Optional callback invoked when tapping the metadata inspector icon button.
  final VoidCallback? onInspectMetadata;

  /// Creates a [PlaybackHeaderBar] displaying [activeTrack], [displayTitle],
  /// [displayArtist], optional [frontCover], [buffer] status, and
  /// [onInspectMetadata] handler.
  const PlaybackHeaderBar({
    super.key,
    required this.activeTrack,
    required this.displayTitle,
    required this.displayArtist,
    this.frontCover,
    required this.buffer,
    this.onInspectMetadata,
  });

  /// Formats [duration] as `MM:SS.t` for compact buffer range pills.
  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final tenths = (duration.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$tenths';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0F1D),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: StudioColors.cardBorder, width: 1.0),
      ),
      child: LayoutBuilder(
        builder: (context, trackConstraints) {
          final isWide = trackConstraints.maxWidth >= 460;
          final thumbnail = Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFF080D1A),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: activeTrack != null
                    ? StudioColors.accentCyan.withValues(alpha: 0.6)
                    : StudioColors.cardBorder,
                width: 0.8,
              ),
            ),
            child: frontCover != null && frontCover!.bytes.isNotEmpty
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(5),
                    child: Image.memory(
                      frontCover!.bytes,
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                    ),
                  )
                : Icon(
                    activeTrack?.icon ?? Icons.audiotrack,
                    color: activeTrack?.iconColor ?? StudioColors.accentCyan,
                    size: 20,
                  ),
          );

          final titleColumn = Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayTitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  displayArtist,
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: StudioColors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );

          final rangeText =
              '${_formatDuration(buffer.start)} - ${_formatDuration(buffer.end)}';
          final actions = <Widget>[
            if (activeTrack != null && onInspectMetadata != null)
              SizedBox(
                width: 28,
                height: 28,
                child: IconButton.filledTonal(
                  icon: const Icon(Icons.info_outline, size: 15),
                  tooltip: 'Inspect Metadata (Static vs Dynamic)',
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    backgroundColor: StudioColors.accentCyan.withValues(
                      alpha: 0.15,
                    ),
                    foregroundColor: StudioColors.accentCyan,
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: onInspectMetadata,
                ),
              ),
            StudioBadge(
              label: buffer.isBuffering
                  ? 'BUFFERING ($rangeText)'
                  : 'Buffer: $rangeText',
              color: buffer.isBuffering
                  ? StudioColors.accentAmber
                  : StudioColors.accentEmerald,
            ),
            StudioBadge(
              label: activeTrack?.resourceBadge ?? 'EMPTY',
              color: activeTrack?.iconColor ?? StudioColors.accentCyan,
            ),
          ];

          final trailingWidgets = isWide
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    for (var i = 0; i < actions.length; i++) ...[
                      if (i > 0) const SizedBox(width: 6),
                      actions[i],
                    ],
                  ],
                )
              : Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: actions,
                );

          if (isWide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                thumbnail,
                const SizedBox(width: 10),
                titleColumn,
                const SizedBox(width: 8),
                trailingWidgets,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  thumbnail,
                  const SizedBox(width: 10),
                  titleColumn,
                ],
              ),
              const SizedBox(height: 6),
              trailingWidgets,
            ],
          );
        },
      ),
    );
  }
}

/// Preview rendering [PlaybackHeaderBar] with active buffered track state.
@StudioPreview(
  name: 'Playback Header Bar',
  group: 'Playback',
  size: Size(600, 92),
)
Widget playbackHeaderBarPreview() {
  return PlaybackHeaderBar(
    activeTrack: StudioPreviewData.sampleTrack,
    displayTitle: StudioPreviewData.sampleTrack.title,
    displayArtist: StudioPreviewData.sampleTrack.artist ?? 'Audio Track',
    buffer: const Buffer(
      start: Duration(seconds: 12),
      end: Duration(minutes: 2, seconds: 15),
      isBuffering: false,
    ),
    onInspectMetadata: StudioPreviewData.noopVoid,
  );
}
