import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';
import '../common/add_source_dialog.dart';
import '../common/compact_slider_overlay.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';

class PlaylistQueueCard extends StatelessWidget {
  final AudioEngineController controller;
  final AudioAnalyzerController? analyzerController;

  const PlaylistQueueCard({
    super.key,
    required this.controller,
    this.analyzerController,
  });

  Widget _buildCurveDropdown(CrossfadeCurve currentCurve) {
    return SizedBox(
      width: 148,
      child: DropdownButtonFormField<CrossfadeCurve>(
        key: ValueKey(currentCurve),
        initialValue: currentCurve,
        isExpanded: true,
        isDense: true,
        dropdownColor: const Color(0xFF0E1424),
        decoration: const InputDecoration(
          labelText: 'Curve',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        ),
        items: const [
          DropdownMenuItem(
            value: CrossfadeCurve.equalPower,
            child: Text(
              'Equal Power',
              style: TextStyle(fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          DropdownMenuItem(
            value: CrossfadeCurve.linear,
            child: Text(
              'Linear',
              style: TextStyle(fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
        onChanged: (curve) {
          if (curve != null) {
            controller.setCrossfadeCurve(curve);
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        controller.queueListenable,
        ?analyzerController,
      ]),
      builder: (context, _) {
        final tracks = controller.availableTracks;
        final xfade = controller.crossfadeConfig;

        return StudioCard(
          icon: Icons.queue_music,
          title: 'DYNAMIC PLAYLIST QUEUE & TRANSITIONS',
          subtitle: 'Dual-Deck Queue Management • Equal Power / Linear Micro-Crossfade',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Crossfade Settings Banner & Queue Actions in one left-aligned Wrap row
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0F1D),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: StudioColors.cardBorder,
                    width: 1.0,
                  ),
                ),
                child: Wrap(
                  alignment: WrapAlignment.start,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _buildCurveDropdown(xfade.curve),

                    // Elegant Compact Floating Slider Overlays for Crossfade Durations
                    CompactSliderControl(
                      icon: Icons.timelapse,
                      label: 'Auto: ${xfade.autoDuration.inSeconds}s',
                      value: xfade.autoDuration.inSeconds.toDouble(),
                      defaultValue: 5.0,
                      min: 0.0,
                      max: 12.0,
                      activeColor: StudioColors.accentCyan,
                      valueFormatter: (s) => '${s.round()}s',
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
                      valueFormatter: (ms) => '${ms.round()}ms',
                      onChanged: (ms) => controller.setManualCrossfadeDuration(
                        Duration(milliseconds: ms.round()),
                      ),
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
                            onTrackAdded: (t) async {
                              await controller.addTrack(t);
                              if (analyzerController != null) {
                                analyzerController!.analyze(
                                  t,
                                  engine: controller.engine,
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
                    StudioBadge(
                      label: '${tracks.length} TRACKS',
                      color: StudioColors.accentCyan,
                    ),
                    IconButton.filledTonal(
                      icon: const Icon(Icons.swap_vert, size: 18),
                      tooltip: 'Reverse Queue via native reorderByIds',
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: StudioColors.cardBorder,
                        foregroundColor: StudioColors.accentPurple,
                        padding: const EdgeInsets.all(6),
                      ),
                      onPressed: controller.reverseQueueByIds,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Reorderable Playlist List with Thumbnails, Analyzed Metadata, and Inspector Modal
              Container(
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFF070B14),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: StudioColors.cardBorder,
                    width: 1.0,
                  ),
                ),
                child: StreamBuilder<List<AudioSource<AudioTrack>>>(
                  stream: controller.engine.stream.queue,
                  initialData: controller.engine.state.queue,
                  builder: (context, queueSnap) {
                    final queue = queueSnap.data ?? [];
                    final tracks = queue.isNotEmpty
                        ? queue
                              .where((e) => e.data != null)
                              .map((e) => e.data!)
                              .toList()
                        : controller.availableTracks;

                    if (tracks.isEmpty) {
                      return const Center(
                        child: Text(
                          'Queue is empty. Add tracks with the + button',
                          style: TextStyle(
                            color: StudioColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      );
                    }

                    return StreamBuilder<int?>(
                      stream: controller.engine.stream.currentIndex,
                      initialData: controller.engine.state.currentIndex,
                      builder: (context, idxSnap) {
                        final currentIdx =
                            idxSnap.data ??
                            controller.engine.state.currentIndex;

                        return Theme(
                          data: Theme.of(context)
                              .copyWith(canvasColor: const Color(0xFF10162A)),
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: tracks.length,
                            onReorderItem: controller.reorderTrack,
                            itemBuilder: (context, index) {
                              final track = tracks[index];
                              final isPlayingThis =
                                  currentIdx != null && index == currentIdx;
                              final itemKey =
                                  queue.isNotEmpty && index < queue.length
                                  ? 'q_${queue[index].id ?? index}_${track.id}'
                                  : 'track_${track.id}_$index';

                              final analysis = analyzerController
                                  ?.getResultForTrack(track);
                              final dynamicMeta = isPlayingThis
                                  ? controller.engine.state.metadata
                                  : null;
                              final frontCover =
                                  dynamicMeta?.frontCover ??
                                  analysis?.metadata?.frontCover;
                              final displayTitle =
                                  (dynamicMeta?.title != null &&
                                      dynamicMeta!.title!.isNotEmpty)
                                  ? dynamicMeta.title!
                                  : (analysis?.metadata?.title != null &&
                                        analysis!.metadata!.title!.isNotEmpty)
                                  ? analysis.metadata!.title!
                                  : track.title;
                              final displayArtist =
                                  (dynamicMeta?.trackArtist != null &&
                                      dynamicMeta!.trackArtist!.isNotEmpty)
                                  ? dynamicMeta.trackArtist!
                                  : (analysis?.metadata?.trackArtist != null &&
                                        analysis!
                                            .metadata!
                                            .trackArtist!
                                            .isNotEmpty)
                                  ? analysis.metadata!.trackArtist!
                                  : (track.artist ?? 'Audio Track');

                              return Padding(
                                key: ValueKey(itemKey),
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
                                  child: Material(
                                    color: Colors.transparent,
                                    child: ListTile(
                                      dense: true,
                                      visualDensity: VisualDensity.compact,
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 2,
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
                                              color: isPlayingThis
                                                  ? StudioColors.accentCyan
                                                  : StudioColors.textMuted,
                                            ),
                                          ),
                                          const SizedBox(width: 6),

                                          // Thumbnail / Embedded Artwork or Fallback Icon
                                          Container(
                                            width: 32,
                                            height: 32,
                                            decoration: BoxDecoration(
                                              color: const Color(0xFF080D1A),
                                              borderRadius:
                                                  BorderRadius.circular(4),
                                              border: Border.all(
                                                color: isPlayingThis
                                                    ? StudioColors.accentCyan
                                                          .withValues(
                                                            alpha: 0.5,
                                                          )
                                                    : StudioColors.cardBorder,
                                                width: 0.8,
                                              ),
                                            ),
                                            child:
                                                frontCover != null &&
                                                    frontCover.bytes.isNotEmpty
                                                ? ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          3,
                                                        ),
                                                    child: Image.memory(
                                                      frontCover.bytes,
                                                      width: 32,
                                                      height: 32,
                                                      fit: BoxFit.cover,
                                                    ),
                                                  )
                                                : Icon(
                                                    isPlayingThis
                                                        ? Icons.equalizer
                                                        : track.icon,
                                                    size: 16,
                                                    color: isPlayingThis
                                                        ? StudioColors
                                                              .accentCyan
                                                        : track.iconColor,
                                                  ),
                                          ),
                                        ],
                                      ),
                                      title: Text(
                                        displayTitle,
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
                                        displayArtist,
                                        style: const TextStyle(
                                          fontSize: 9,
                                          color: StudioColors.textSecondary,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      trailing: Wrap(
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        spacing: 4,
                                        children: [
                                          if (queue.isNotEmpty &&
                                              index < queue.length &&
                                              queue[index].id != null)
                                            StudioBadge(
                                              label: 'ID #${queue[index].id}',
                                              color: StudioColors.accentPurple,
                                            ),
                                          StudioBadge(
                                            label: track.resourceBadge,
                                            color: track.iconColor,
                                          ),
                                        ],
                                      ),
                                      onTap: () async {
                                        await controller.selectTrack(
                                          track,
                                          autoPlay: true,
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
