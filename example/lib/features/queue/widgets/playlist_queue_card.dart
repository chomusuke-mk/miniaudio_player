import 'package:material_ui/material_ui.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../../core/models/audio_track.dart';
import '../../../core/theme/studio_colors.dart';
import '../../../shared/widgets/compact_slider_overlay.dart';
import '../../../shared/widgets/studio_badge.dart';
import '../../../shared/widgets/studio_card.dart';
import '../../analyzer/controllers/audio_analyzer_controller.dart';
import '../../console/controllers/audio_engine_controller.dart';
import 'add_source_dialog.dart';
import 'queue_track_tile.dart';

/// Controller-bound card managing crossfade transition curves/durations and the
/// reorderable multi-source playback queue.
class PlaylistQueueCard extends StatelessWidget {
  /// Controller owning queue ordering, selection, and crossfade RPCs.
  final AudioEngineController controller;

  /// Optional acoustic analyzer controller supplying cached tags and artwork.
  final AudioAnalyzerController? analyzerController;

  /// Creates a [PlaylistQueueCard] bound to [controller] and optional
  /// [analyzerController].
  const PlaylistQueueCard({
    super.key,
    required this.controller,
    this.analyzerController,
  });

  /// Builds the crossfade transition curve dropdown selector for [currentCurve].
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

  /// Opens [AddSourceDialog] and appends/analyzes the added track.
  void _openAddSourceDialog(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (_) => AddSourceDialog(
        onTrackAdded: (track) async {
          MapLogger.info('[QUEUE:UI] Adding custom source "${track.title}"');
          await controller.addTrack(track);
          if (analyzerController != null) {
            analyzerController!.analyze(track, engine: controller.engine);
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
          subtitle:
              'Dual-Deck Queue Management • Equal Power / Linear Micro-Crossfade',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                      label:
                          'Manual: ${xfade.manualDuration.inMilliseconds}ms',
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
                      onPressed: () => _openAddSourceDialog(context),
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
                    final displayTracks = queue.isNotEmpty
                        ? queue
                              .where((entry) => entry.data != null)
                              .map((entry) => entry.data!)
                              .toList()
                        : controller.availableTracks;

                    if (displayTracks.isEmpty) {
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
                          data: Theme.of(
                            context,
                          ).copyWith(canvasColor: const Color(0xFF10162A)),
                          child: ReorderableListView.builder(
                            buildDefaultDragHandles: false,
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            itemCount: displayTracks.length,
                            onReorderItem: controller.reorderTrack,
                            itemBuilder: (context, index) {
                              final track = displayTracks[index];
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

                              return QueueTrackTile(
                                key: ValueKey(itemKey),
                                track: track,
                                index: index,
                                isPlaying: isPlayingThis,
                                displayTitle: displayTitle,
                                displayArtist: displayArtist,
                                frontCover: frontCover,
                                sourceId:
                                    queue.isNotEmpty && index < queue.length
                                    ? queue[index].id
                                    : null,
                                onTap: () async {
                                  MapLogger.info(
                                    '[QUEUE:UI] Selected track "${track.title}" at index $index',
                                  );
                                  await controller.selectTrack(
                                    track,
                                    autoPlay: true,
                                  );
                                },
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
