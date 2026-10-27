import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/add_source_dialog.dart';
import '../common/compact_slider_overlay.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

class PlaylistQueueCard extends StatelessWidget {
  final AudioEngineController controller;

  const PlaylistQueueCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final tracks = controller.availableTracks;
        final selectedTrack = controller.selectedTrack;
        final xfade = controller.crossfadeConfig;

        return StudioCard(
          icon: Icons.queue_music,
          title: 'DYNAMIC PLAYLIST QUEUE & TRANSITIONS',
          subtitle: 'Dual-Deck Queue Management • Equal Power / Linear Micro-Crossfade',
          trailing: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 6,
            children: [
              StudioBadge(
                label: '${tracks.length} TRACKS',
                color: StudioColors.accentCyan,
              ),
              IconButton.filledTonal(
                icon: const Icon(Icons.add, size: 18),
                tooltip: 'Add URL, URI, or file to queue',
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  backgroundColor: StudioColors.cardBorder,
                  foregroundColor: StudioColors.accentCyan,
                  padding: const EdgeInsets.all(6),
                ),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (_) => AddSourceDialog(
                      onTrackAdded: controller.addTrack,
                    ),
                  );
                },
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Crossfade Settings Banner: Curve selection & Compact floating slider overlays
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0F1D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                ),
                child: Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    const Text(
                      'CURVE: ',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: StudioColors.textSecondary,
                      ),
                    ),
                    ChoiceChip(
                      label: const Text(
                        'Equal Power',
                        style: TextStyle(fontSize: 9.5),
                      ),
                      selected: xfade.curve == CrossfadeCurve.equalPower,
                      selectedColor: StudioColors.accentCyan,
                      backgroundColor: StudioColors.backgroundDark,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      onSelected: (_) =>
                          controller.setCrossfadeCurve(CrossfadeCurve.equalPower),
                    ),
                    ChoiceChip(
                      label: const Text(
                        'Linear',
                        style: TextStyle(fontSize: 9.5),
                      ),
                      selected: xfade.curve == CrossfadeCurve.linear,
                      selectedColor: StudioColors.accentCyan,
                      backgroundColor: StudioColors.backgroundDark,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0),
                      onSelected: (_) =>
                          controller.setCrossfadeCurve(CrossfadeCurve.linear),
                    ),

                    // Elegant Compact Floating Slider Overlays for Crossfade Durations
                    CompactSliderControl(
                      icon: Icons.timelapse,
                      label: 'Auto: ${xfade.duration.inSeconds}s',
                      value: xfade.duration.inSeconds.toDouble(),
                      defaultValue: 5.0,
                      min: 0.0,
                      max: 12.0,
                      activeColor: StudioColors.accentCyan,
                      onChanged: (s) => controller.setCrossfadeDuration(
                        Duration(seconds: s.round()),
                      ),
                    ),
                    CompactSliderControl(
                      icon: Icons.touch_app,
                      label: 'Manual: ${xfade.manualDuration.inMilliseconds}ms',
                      value: xfade.manualDuration.inMilliseconds.toDouble(),
                      defaultValue: 100.0,
                      min: 0.0,
                      max: 1500.0,
                      activeColor: StudioColors.accentPurple,
                      onChanged: (ms) => controller.setManualCrossfadeDuration(
                        Duration(milliseconds: ms.round()),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Reorderable Playlist List with Scroll
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                ),
                child: tracks.isEmpty
                    ? const Center(
                        child: Text(
                          'Queue is empty. Add tracks with the + button',
                          style: TextStyle(color: StudioColors.textMuted, fontSize: 11),
                        ),
                      )
                    : Theme(
                        data: Theme.of(context).copyWith(
                          canvasColor: const Color(0xFF10162A),
                        ),
                        child: ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: tracks.length,
                          onReorderItem: controller.reorderTrack,
                          itemBuilder: (context, index) {
                            final track = tracks[index];
                            final isPlayingThis = track.id == selectedTrack?.id;

                            return Padding(
                              key: ValueKey(track.id),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              child: Material(
                                color: isPlayingThis
                                    ? const Color(0xFF152238)
                                    : const Color(0xFF0C1222),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(6),
                                  side: BorderSide(
                                    color: isPlayingThis
                                        ? StudioColors.accentCyan
                                        : StudioColors.cardBorder,
                                    width: isPlayingThis ? 1.2 : 0.8,
                                  ),
                                ),
                                child: ListTile(
                                  dense: true,
                                  visualDensity: VisualDensity.compact,
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 0,
                                  ),
                                  leading: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: MouseRegion(
                                          cursor: SystemMouseCursors.grab,
                                          child: const Padding(
                                            padding: EdgeInsets.symmetric(
                                              horizontal: 2,
                                              vertical: 4,
                                            ),
                                            child: Icon(
                                              Icons.drag_indicator,
                                              size: 18,
                                              color: StudioColors.textMuted,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Icon(
                                        isPlayingThis
                                            ? Icons.equalizer
                                            : track.icon,
                                        size: 18,
                                        color: isPlayingThis
                                            ? StudioColors.accentCyan
                                            : track.iconColor,
                                      ),
                                    ],
                                  ),
                                  title: Text(
                                    track.title,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: isPlayingThis
                                        ? FontWeight.bold
                                        : FontWeight.w500,
                                      color: isPlayingThis
                                          ? StudioColors.accentCyan
                                          : Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  subtitle: Text(
                                    track.artist ?? 'Audio Track',
                                    style: const TextStyle(
                                      fontSize: 9,
                                      color: StudioColors.textSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  trailing: StudioBadge(
                                    label: track.resourceBadge,
                                    color: track.iconColor,
                                  ),
                                  onTap: () {
                                    controller.selectTrack(track, autoPlay: true);
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
