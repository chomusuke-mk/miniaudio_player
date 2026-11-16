import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/metadata_inspector_modal.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../painters/waveform_painter.dart';

class PlaybackEngineCard extends StatelessWidget {
  final AudioEngineController controller;
  final AudioAnalyzerController? analyzerController;

  const PlaybackEngineCard({
    super.key,
    required this.controller,
    this.analyzerController,
  });

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final ms = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
    return '$minutes:$seconds.$ms';
  }

  void _seekToFraction(BuildContext context, double fraction, Duration dur) {
    if (dur.inMilliseconds <= 0) return;
    final clamped = fraction.clamp(0.0, 1.0);
    final targetMs = (clamped * dur.inMilliseconds).round();
    controller.engine.action.seek(Duration(milliseconds: targetMs));
  }

  @override
  Widget build(BuildContext context) {
    final engine = controller.engine;

    return StudioCard(
      icon: Icons.graphic_eq,
      title: 'HIGH-RES AUDIO PLAYBACK ENGINE',
      subtitle: 'Dual-Deck Hardware Threads • Sonic DSP Varispeed',
      trailing: ListenableBuilder(
        listenable: controller.trackSelectionListenable,
        builder: (context, _) {
          final track = controller.selectedTrack;
          return StreamBuilder<AudioSource<AudioTrack>?>(
            stream: engine.stream.currentItem,
            initialData: engine.state.currentItem,
            builder: (context, currentSnap) {
              final activeTrack = currentSnap.data?.data ?? track;
              return StreamBuilder<AudioInfo?>(
                stream: engine.stream.audioInfo,
                initialData: engine.state.audioInfo,
                builder: (context, snapshot) {
                  return StudioBadge(
                    label: TrackFormatInfo.deduceFormatBadge(
                      activeTrack,
                      bitrate: snapshot.data?.bitrate ?? 0,
                    ),
                    color: StudioColors.accentAmber,
                  );
                },
              );
            },
          );
        },
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Current Track Display (No dropdown, clean active track banner with reactive thumbnail & metadata inspector)
          ListenableBuilder(
            listenable: Listenable.merge([
              controller.trackSelectionListenable,
              ?analyzerController,
            ]),
            builder: (context, _) {
              final track = controller.selectedTrack;
              return StreamBuilder<AudioSource<AudioTrack>?>(
                stream: engine.stream.currentItem,
                initialData: engine.state.currentItem,
                builder: (context, currentSnap) {
                  final activeTrack = currentSnap.data?.data ?? track;
                  return StreamBuilder<AudioMetadata?>(
                    stream: engine.stream.metadata,
                    initialData: engine.state.metadata,
                    builder: (context, metaSnap) {
                      final dynamicMeta =
                          metaSnap.data ?? engine.state.metadata;
                      final analysis = analyzerController?.getResultForTrack(
                        activeTrack,
                      );

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
                          : (activeTrack?.title ?? 'No track selected');

                      final displayArtist =
                          (dynamicMeta?.trackArtist != null &&
                              dynamicMeta!.trackArtist!.isNotEmpty)
                          ? dynamicMeta.trackArtist!
                          : (analysis?.metadata?.trackArtist != null &&
                                analysis!.metadata!.trackArtist!.isNotEmpty)
                          ? analysis.metadata!.trackArtist!
                          : (activeTrack?.artist ??
                                'Select a track from the queue');

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0F1D),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: StudioColors.cardBorder,
                            width: 1.0,
                          ),
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
                                      ? StudioColors.accentCyan.withValues(
                                          alpha: 0.6,
                                        )
                                      : StudioColors.cardBorder,
                                  width: 0.8,
                                ),
                              ),
                              child:
                                  frontCover != null &&
                                      frontCover.bytes.isNotEmpty
                                  ? ClipRRect(
                                      borderRadius: BorderRadius.circular(5),
                                      child: Image.memory(
                                        frontCover.bytes,
                                        width: 38,
                                        height: 38,
                                        fit: BoxFit.cover,
                                      ),
                                    )
                                  : Icon(
                                      activeTrack?.icon ?? Icons.audiotrack,
                                      color:
                                          activeTrack?.iconColor ??
                                          StudioColors.accentCyan,
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

                            final trailingWidgets = StreamBuilder<Buffer>(
                              stream: engine.stream.buffer,
                              initialData: engine.state.buffer,
                              builder: (context, bufSnap) {
                                final buf = bufSnap.data ?? engine.state.buffer;
                                final rangeText =
                                    '${_formatDuration(buf.start)} - ${_formatDuration(buf.end)}';
                                final bufferBadge = StudioBadge(
                                  label: buf.isBuffering
                                      ? 'BUFFERING ($rangeText)'
                                      : 'Buffer: $rangeText',
                                  color: buf.isBuffering
                                      ? StudioColors.accentAmber
                                      : StudioColors.accentEmerald,
                                );

                                final actions = <Widget>[
                                  if (activeTrack != null)
                                    SizedBox(
                                      width: 28,
                                      height: 28,
                                      child: IconButton.filledTonal(
                                        icon: const Icon(
                                          Icons.info_outline,
                                          size: 15,
                                        ),
                                        tooltip:
                                            'Inspect Metadata (Static vs Dynamic)',
                                        visualDensity: VisualDensity.compact,
                                        style: IconButton.styleFrom(
                                          backgroundColor: StudioColors
                                              .accentCyan
                                              .withValues(alpha: 0.15),
                                          foregroundColor:
                                              StudioColors.accentCyan,
                                          padding: EdgeInsets.zero,
                                        ),
                                        onPressed: () {
                                          showDialog(
                                            context: context,
                                            builder: (_) =>
                                                MetadataInspectorModal(
                                                  track: activeTrack,
                                                  staticMetadata:
                                                      analysis?.metadata,
                                                  dynamicMetadata:
                                                      engine.state.metadata,
                                                  staticAudioInfo:
                                                      analysis?.audioInfo,
                                                  dynamicAudioInfo:
                                                      engine.state.audioInfo,
                                                ),
                                          );
                                        },
                                      ),
                                    ),
                                  bufferBadge,
                                  StudioBadge(
                                    label:
                                        activeTrack?.resourceBadge ?? 'EMPTY',
                                    color:
                                        activeTrack?.iconColor ??
                                        StudioColors.accentCyan,
                                  ),
                                ];

                                if (isWide) {
                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.center,
                                    children: [
                                      for (var i = 0; i < actions.length; i++)
                                        ...[
                                          if (i > 0) const SizedBox(width: 6),
                                          actions[i],
                                        ],
                                    ],
                                  );
                                }

                                return Wrap(
                                  alignment: WrapAlignment.start,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 6,
                                  runSpacing: 4,
                                  children: actions,
                                );
                              },
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
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 10),

          // 2. Waveform Progress Bar & Seek
          ListenableBuilder(
            listenable: controller.trackSelectionListenable,
            builder: (context, _) {
              final track = controller.selectedTrack;
              return StreamBuilder<Duration?>(
                stream: engine.stream.duration,
                initialData: engine.state.duration,
                builder: (context, durSnap) {
                  final dur = durSnap.data ?? engine.state.duration;
                  return StreamBuilder<Duration>(
                    stream: engine.stream.position,
                    initialData: engine.state.position,
                    builder: (context, posSnap) {
                      final pos = posSnap.data ?? Duration.zero;
                      final progress = (dur != null && dur.inMilliseconds > 0)
                          ? (pos.inMilliseconds / dur.inMilliseconds).clamp(
                              0.0,
                              1.0,
                            )
                          : 0.0;

                      return StreamBuilder<Buffer>(
                        stream: engine.stream.buffer,
                        initialData: engine.state.buffer,
                        builder: (context, bufSnap) {
                          final buf = bufSnap.data ?? engine.state.buffer;
                          final isLocal =
                              track?.source.isMemory == true ||
                              (track?.source.uri != null &&
                                  !track!.source.uri!.toLowerCase().startsWith(
                                    'http',
                                  ));
                          final bufferedProgress = isLocal
                              ? 1.0
                              : (dur != null && dur.inMilliseconds > 0
                                    ? (buf.end.inMilliseconds /
                                              dur.inMilliseconds)
                                          .clamp(0.0, 1.0)
                                    : 0.0);

                          return Column(
                            children: [
                              LayoutBuilder(
                                builder: (ctx, constraints) {
                                  return GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) {
                                      if (dur == null) return;
                                      final frac =
                                          details.localPosition.dx /
                                          constraints.maxWidth;
                                      _seekToFraction(context, frac, dur);
                                    },
                                    onHorizontalDragStart: (details) {
                                      if (dur == null) return;
                                      final frac =
                                          details.localPosition.dx /
                                          constraints.maxWidth;
                                      _seekToFraction(context, frac, dur);
                                    },
                                    onHorizontalDragUpdate: (details) {
                                      if (dur == null) return;
                                      final frac =
                                          details.localPosition.dx /
                                          constraints.maxWidth;
                                      _seekToFraction(context, frac, dur);
                                    },
                                    child: Container(
                                      height: 44,
                                      width: double.infinity,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF070B14),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: StudioColors.cardBorder,
                                          width: 1.0,
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(5),
                                        child: RepaintBoundary(
                                          child: ListenableBuilder(
                                            listenable:
                                                controller.waveformListenable,
                                            builder: (context, _) {
                                              return CustomPaint(
                                                size: Size(
                                                  constraints.maxWidth,
                                                  44,
                                                ),
                                                painter: WaveformPainter(
                                                  points:
                                                      controller.waveformPoints,
                                                  progress: progress,
                                                  bufferedProgress:
                                                      bufferedProgress,
                                                  playedColor:
                                                      StudioColors.accentCyan,
                                                  unplayedColor: StudioColors
                                                      .cardBorderFocused,
                                                ),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                              const SizedBox(height: 4),

                              // Current time (left) and total time (right) under waveform
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Flexible(
                                    child: Text(
                                      _formatDuration(pos),
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: StudioColors.accentCyan,
                                        fontFamily: 'monospace',
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  Flexible(
                                    child: Text(
                                      dur != null
                                          ? _formatDuration(dur)
                                          : 'LIVE',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontWeight: FontWeight.w700,
                                        color: StudioColors.textSecondary,
                                        fontFamily: 'monospace',
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
          const SizedBox(height: 8),

              // 3. Playback Controls Row: Left (Transport) & Right (Vol, Speed, Pitch Overlays)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 560;

                  // Left Controls: prev, play/pause, next, stop, random, loop
                  final leftControls = SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: StreamBuilder<PlaybackState>(
                      stream: engine.stream.playbackState,
                      initialData: engine.state.playbackState,
                      builder: (context, stateSnap) {
                        final state = stateSnap.data ?? PlaybackState.stopped;
                        final isPlaying = state == PlaybackState.playing;

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.skip_previous, size: 20),
                              color: StudioColors.textPrimary,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'Previous',
                              onPressed: controller.previousTrack,
                            ),
                            IconButton(
                              icon: Icon(
                                isPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_filled,
                                size: 32,
                              ),
                              color: StudioColors.accentCyan,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 36,
                                minHeight: 36,
                              ),
                              tooltip: isPlaying ? 'Pause' : 'Play',
                              onPressed: () {
                                if (isPlaying) {
                                  engine.action.pause();
                                } else {
                                  engine.action.play();
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.skip_next, size: 20),
                              color: StudioColors.textPrimary,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'Next',
                              onPressed: controller.nextTrack,
                            ),
                            IconButton(
                              icon: const Icon(Icons.stop, size: 20),
                              color: StudioColors.accentRose,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 32,
                              ),
                              tooltip: 'Stop',
                              onPressed: engine.action.stop,
                            ),
                            StreamBuilder<bool>(
                              stream: engine.stream.isShuffled,
                              initialData: engine.state.isShuffled,
                              builder: (context, shuffleSnap) {
                                final isShuffle = shuffleSnap.data ?? false;
                                return IconButton(
                                  icon: const Icon(Icons.shuffle, size: 18),
                                  color: isShuffle
                                      ? StudioColors.accentCyan
                                      : StudioColors.textMuted,
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  tooltip: isShuffle
                                      ? 'Shuffle (On)'
                                      : 'Shuffle (Off)',
                                  onPressed: controller.toggleShuffle,
                                );
                              },
                            ),
                            StreamBuilder<LoopMode>(
                              stream: engine.stream.loopMode,
                              initialData: engine.state.loopMode,
                              builder: (context, loopSnap) {
                                final mode = loopSnap.data ?? LoopMode.off;
                                final isLoop = mode != LoopMode.off;
                                return IconButton(
                                  icon: Icon(
                                    mode == LoopMode.one
                                        ? Icons.repeat_one
                                        : Icons.repeat,
                                    size: 18,
                                  ),
                                  color: isLoop
                                      ? StudioColors.accentCyan
                                      : StudioColors.textMuted,
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(
                                    minWidth: 32,
                                    minHeight: 32,
                                  ),
                                  tooltip:
                                      'Loop Mode: ${mode.name.toUpperCase()}',
                                  onPressed: controller.toggleLoop,
                                );
                              },
                            ),
                          ],
                        );
                      },
                    ),
                  );

                  // Right Controls: Elegant Compact Floating Slider Overlays (Vol, Speed, Pitch)
                  final rightControls = ListenableBuilder(
                    listenable: controller.transportControlsListenable,
                    builder: (context, _) {
                      return Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          // Volume Overlay Control
                          CompactSliderControl(
                            icon: Icons.volume_up,
                            label: 'Vol: ${(controller.volume * 100).round()}%',
                            value: controller.volume.clamp(0.0, 2.0),
                            defaultValue: 1.0,
                            min: 0.0,
                            max: 2.0,
                            activeColor: StudioColors.accentEmerald,
                            valueFormatter: (v) => '${(v * 100).round()}%',
                            onChanged: controller.setVolume,
                          ),
                          // Speed Overlay Control
                          CompactSliderControl(
                            icon: Icons.speed,
                            label: '${controller.rate.toStringAsFixed(2)}x',
                            value: controller.rate,
                            defaultValue: 1.0,
                            min: 0.25,
                            max: 4.0,
                            activeColor: StudioColors.accentCyan,
                            valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
                            onChanged: controller.setRate,
                          ),
                          // Pitch Overlay Control
                          CompactSliderControl(
                            icon: Icons.tune,
                            label:
                                'Pitch: ${controller.pitch.toStringAsFixed(2)}x',
                            value: controller.pitch,
                            defaultValue: 1.0,
                            min: 0.5,
                            max: 2.0,
                            activeColor: StudioColors.accentPurple,
                            valueFormatter: (v) => '${v.toStringAsFixed(2)}x',
                            onChanged: controller.setPitch,
                          ),
                        ],
                      );
                    },
                  );

                  if (isNarrow) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: leftControls,
                        ),
                        const SizedBox(height: 6),
                        rightControls,
                      ],
                    );
                  }

                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(child: leftControls),
                      const SizedBox(width: 8),
                      Flexible(child: rightControls),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),

              // =============================================================
              // NEW: Mini Recording Menu directly below Transport Controls
              // =============================================================
              _buildRecordingMenu(context),
            ],
          ),
        );
  }

  /// Small recording control bar directly below transport controls
  Widget _buildRecordingMenu(BuildContext context) {
    return ListenableBuilder(
      listenable: controller.recordingListenable,
      builder: (context, _) {
        final isRec = controller.isRecording;
        final dur = controller.recordedDuration;

        return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0C101C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isRec ? StudioColors.accentRose : StudioColors.cardBorder,
          width: isRec ? 1.4 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.fiber_manual_record,
                size: 14,
                color: isRec ? StudioColors.accentRose : StudioColors.textMuted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isRec ? 'RECORDING IN PROGRESS' : 'LIVE DISK RECORDER',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: isRec
                        ? StudioColors.accentRose
                        : StudioColors.accentCyan,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isRec) ...[
                const SizedBox(width: 4),
                StreamBuilder<Duration>(
                  stream: controller.engine.stream.recordedDuration,
                  initialData: controller.engine.state.recordedDuration,
                  builder: (context, snap) {
                    final d = snap.data ?? dur;
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: StudioColors.accentRose.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(
                          color: StudioColors.accentRose,
                          width: 0.8,
                        ),
                      ),
                      child: Text(
                        _formatDuration(d),
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                          color: StudioColors.accentRose,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              // Record/Stop Action Button
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: isRec
                      ? StudioColors.accentRose
                      : const Color(0xFF1E283E),
                  foregroundColor: isRec
                      ? Colors.white
                      : StudioColors.accentRose,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: isRec
                          ? StudioColors.accentRose
                          : StudioColors.cardBorder,
                    ),
                  ),
                ),
                icon: Icon(
                  isRec ? Icons.stop : Icons.fiber_manual_record,
                  size: 16,
                  color: isRec ? Colors.white : StudioColors.accentRose,
                ),
                label: Text(
                  isRec ? 'STOP' : 'RECORD',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                onPressed: () async {
                  if (isRec) {
                    final res = await controller.stopRecording();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          backgroundColor: const Color(0xFF0E172A),
                          content: Text(
                            'Recorded ${_formatDuration(res.duration)} (${(res.bytesWritten / 1024).round()} KB) to ${res.path.split("/").last}',
                            style: const TextStyle(
                              color: StudioColors.accentEmerald,
                            ),
                          ),
                          duration: const Duration(seconds: 4),
                        ),
                      );
                    }
                  } else {
                    await controller.startRecording();
                  }
                },
              ),

              // Format selector
              if (!isRec)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioFileFormat>(
                      value: controller.recordingFormat,
                      isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 16),
                      dropdownColor: const Color(0xFF0E172A),
                      items: AudioFileFormat.values.map((f) {
                        return DropdownMenuItem(
                          value: f,
                          child: Text(
                            f.name.toUpperCase(),
                            style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      }).toList(),
                      onChanged: (fmt) {
                        if (fmt != null) controller.setRecordingFormat(fmt);
                      },
                    ),
                  ),
                ),

              // Source selector
              if (!isRec)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioOutputSource>(
                      value: controller.recordingSource,
                      isDense: true,
                      icon: const Icon(Icons.arrow_drop_down, size: 16),
                      dropdownColor: const Color(0xFF0E172A),
                      items: const [
                        DropdownMenuItem(
                          value: AudioOutputSource.all,
                          child: Text(
                            'All Mix',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.musicMix,
                          child: Text(
                            'Music',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.activeTrack,
                          child: Text(
                            'Active',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.standbyTrack,
                          child: Text(
                            'Cue',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.voiceOnly,
                          child: Text(
                            'Voice Only',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                      onChanged: (src) {
                        if (src != null) controller.setRecordingSource(src);
                      },
                    ),
                  ),
                ),

              if (controller.lastRecordingResult != null && !isRec)
                Flexible(
                  child: Text(
                    'Last: ${controller.lastRecordingResult!.path.split("/").last} (${_formatDuration(controller.lastRecordingResult!.duration)})',
                    style: const TextStyle(
                      fontSize: 9.5,
                      color: StudioColors.textMuted,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  },
);
  }
}
