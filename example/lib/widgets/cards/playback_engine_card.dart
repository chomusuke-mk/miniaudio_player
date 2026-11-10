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

    return ListenableBuilder(
      listenable: Listenable.merge([
        controller,
        ?analyzerController,
      ]),
      builder: (context, _) {
        final track = controller.selectedTrack;

        return StudioCard(
          icon: Icons.graphic_eq,
          title: 'HIGH-RES AUDIO PLAYBACK ENGINE',
          subtitle: 'Dual-Deck Hardware Threads • Sonic DSP Varispeed',
          trailing: StreamBuilder<AudioSource<AudioTrack>?>(
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
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Current Track Display (No dropdown, clean active track banner with reactive thumbnail & metadata inspector)
              StreamBuilder<AudioSource<AudioTrack>?>(
                stream: engine.stream.currentItem,
                initialData: engine.state.currentItem,
                builder: (context, currentSnap) {
                  final activeTrack = currentSnap.data?.data ?? track;
                  return StreamBuilder<AudioMetadata?>(
                    stream: engine.stream.metadata,
                    initialData: engine.state.metadata,
                    builder: (context, metaSnap) {
                      final dynamicMeta = metaSnap.data ?? engine.state.metadata;
                      final analysis = analyzerController?.getResultForTrack(activeTrack);

                      final frontCover = dynamicMeta?.frontCover ?? analysis?.metadata?.frontCover;

                      final displayTitle = (dynamicMeta?.title != null && dynamicMeta!.title!.isNotEmpty)
                          ? dynamicMeta.title!
                          : (analysis?.metadata?.title != null && analysis!.metadata!.title!.isNotEmpty)
                              ? analysis.metadata!.title!
                              : (activeTrack?.title ?? 'No track selected');

                      final displayArtist = (dynamicMeta?.artist != null && dynamicMeta!.artist!.isNotEmpty)
                          ? dynamicMeta.artist!
                          : (analysis?.metadata?.artist != null && analysis!.metadata!.artist!.isNotEmpty)
                              ? analysis.metadata!.artist!
                              : (activeTrack?.artist ?? 'Select a track from the queue');

                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0A0F1D),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Thumbnail / Embedded Artwork or Fallback Icon
                            Container(
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
                              child: frontCover != null && frontCover.bytes.isNotEmpty
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
                                      color: activeTrack?.iconColor ?? StudioColors.accentCyan,
                                      size: 20,
                                    ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
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
                            ),
                            const SizedBox(width: 8),
                            // Trailing Actions: Metadata Inspector & Resource Badge neatly aligned
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                if (activeTrack != null) ...[
                                  SizedBox(
                                    width: 28,
                                    height: 28,
                                    child: IconButton.filledTonal(
                                      icon: const Icon(Icons.info_outline, size: 15),
                                      tooltip: 'Inspect Metadata (Static vs Dynamic)',
                                      visualDensity: VisualDensity.compact,
                                      style: IconButton.styleFrom(
                                        backgroundColor: StudioColors.accentCyan.withValues(alpha: 0.15),
                                        foregroundColor: StudioColors.accentCyan,
                                        padding: EdgeInsets.zero,
                                      ),
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (_) => MetadataInspectorModal(
                                            track: activeTrack,
                                            staticMetadata: analysis?.metadata,
                                            dynamicMetadata: engine.state.metadata,
                                            staticAudioInfo: analysis?.audioInfo,
                                            dynamicAudioInfo: engine.state.audioInfo,
                                            staticReplayGain: analysis?.replayGain,
                                            dynamicReplayGain: engine.state.replayGain,
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                StudioBadge(
                                  label: activeTrack?.resourceBadge ?? 'EMPTY',
                                  color: activeTrack?.iconColor ?? StudioColors.accentCyan,
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 10),

              // 2. Waveform Progress Bar & Seek
              StreamBuilder<Duration>(
                stream: engine.stream.position,
                initialData: engine.state.position,
                builder: (context, posSnap) {
                  final pos = posSnap.data ?? Duration.zero;
                  final dur = engine.state.duration;
                  final progress = (dur != null && dur.inMilliseconds > 0)
                      ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                      : 0.0;

                  return StreamBuilder<Buffer>(
                    stream: engine.stream.buffer,
                    initialData: engine.state.buffer,
                    builder: (context, bufSnap) {
                      final buf = bufSnap.data ?? engine.state.buffer;
                      final isLocal = track?.source.isMemory == true ||
                          (track?.source.uri != null &&
                              !track!.source.uri!.toLowerCase().startsWith('http'));
                      final bufferedProgress = isLocal
                          ? 1.0
                          : (dur != null && dur.inMilliseconds > 0
                              ? (buf.end.inMilliseconds / dur.inMilliseconds)
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
                                  final frac = details.localPosition.dx /
                                      constraints.maxWidth;
                                  _seekToFraction(context, frac, dur);
                                },
                                onHorizontalDragStart: (details) {
                                  if (dur == null) return;
                                  final frac = details.localPosition.dx /
                                      constraints.maxWidth;
                                  _seekToFraction(context, frac, dur);
                                },
                                onHorizontalDragUpdate: (details) {
                                  if (dur == null) return;
                                  final frac = details.localPosition.dx /
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
                                    child: CustomPaint(
                                      size: Size(constraints.maxWidth, 44),
                                      painter: WaveformPainter(
                                        points: controller.waveformPoints,
                                        progress: progress,
                                        bufferedProgress: bufferedProgress,
                                        playedColor: StudioColors.accentCyan,
                                        unplayedColor:
                                            StudioColors.cardBorderFocused,
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
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
                                  dur != null ? _formatDuration(dur) : 'LIVE',
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
                          const SizedBox(height: 4),

                          // Continuous Buffer Range & Telemetry HUD
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF070B14),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: StudioColors.cardBorder, width: 0.8),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  buf.isBuffering ? Icons.sync : Icons.download_done,
                                  size: 13,
                                  color: buf.isBuffering
                                      ? StudioColors.accentAmber
                                      : StudioColors.accentCyan,
                                ),
                                const SizedBox(width: 5),
                                Expanded(
                                  child: Text(
                                    'Buffer: ${_formatDuration(buf.start)} - ${_formatDuration(buf.end)}',
                                    style: const TextStyle(
                                      fontSize: 9.5,
                                      fontFamily: 'monospace',
                                      color: StudioColors.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: buf.isBuffering
                                      ? const StudioBadge(
                                          label: 'BUFFERING',
                                          color: StudioColors.accentAmber,
                                        )
                                      : StudioBadge(
                                          label: '${_formatDuration(buf.end - buf.start)} cached',
                                          color: StudioColors.accentEmerald,
                                        ),
                                ),
                              ],
                            ),
                          ),
                        ],
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
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              tooltip: 'Next',
                              onPressed: controller.nextTrack,
                            ),
                            IconButton(
                              icon: const Icon(Icons.stop, size: 20),
                              color: StudioColors.accentRose,
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  tooltip: isShuffle ? 'Shuffle (On)' : 'Shuffle (Off)',
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
                                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  tooltip: 'Loop Mode: ${mode.name.toUpperCase()}',
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
                  final rightControls = Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      // Volume Overlay Control
                      CompactSliderControl(
                        icon: Icons.volume_up,
                        label: 'Vol: ${(controller.volume * 100).round()}%',
                        value: controller.volume,
                        defaultValue: 1.0,
                        min: 0.0,
                        max: 1.0,
                        activeColor: StudioColors.accentEmerald,
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
                        onChanged: controller.setRate,
                      ),
                      // Pitch Overlay Control
                      CompactSliderControl(
                        icon: Icons.tune,
                        label: 'Pitch: ${controller.pitch.toStringAsFixed(2)}x',
                        value: controller.pitch,
                        defaultValue: 1.0,
                        min: 0.5,
                        max: 2.0,
                        activeColor: StudioColors.accentPurple,
                        onChanged: controller.setPitch,
                      ),
                    ],
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

              const SizedBox(height: 10),

              // 4. Hardware Buffer Configuration
              DropdownButtonFormField<int>(
                initialValue: controller.selectedBufferSize,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Hardware Buffer Period',
                  prefixIcon: Icon(Icons.memory, size: 16),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                ),
                items: const [
                  DropdownMenuItem(
                    value: 0,
                    child: Text(
                      'Auto (Miniaudio Engine Default)',
                      style: TextStyle(fontSize: 10.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 256,
                    child: Text(
                      '256 frames (~5.8ms @ 44.1kHz)',
                      style: TextStyle(fontSize: 10.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 512,
                    child: Text(
                      '512 frames (~11.6ms @ 44.1kHz)',
                      style: TextStyle(fontSize: 10.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 1024,
                    child: Text(
                      '1024 frames (~23.2ms @ 44.1kHz)',
                      style: TextStyle(fontSize: 10.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 2048,
                    child: Text(
                      '2048 frames (~46.4ms @ 44.1kHz)',
                      style: TextStyle(fontSize: 10.5),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (size) {
                  if (size != null) controller.setBufferSize(size);
                },
              ),
              const SizedBox(height: 10),

              // 5. Native Pause on Device Disconnect Toggle
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: StudioColors.cardBackgroundDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.pause_circle_outline,
                                size: 14,
                                color: controller.pauseOnDeviceChange
                                    ? StudioColors.accentCyan
                                    : StudioColors.textMuted,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'Pause on Device Change',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: StudioColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.pauseOnDeviceChange
                                ? 'Immediate native pause (0ms leak) if physical endpoint changes'
                                : 'Inactive: audio switches to new endpoint without pausing',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          controller.pauseOnDeviceChange ? 'ON' : 'OFF',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: controller.pauseOnDeviceChange
                                ? StudioColors.accentCyan
                                : StudioColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Switch(
                          value: controller.pauseOnDeviceChange,
                          activeThumbColor: StudioColors.accentCyan,
                          onChanged: (val) => controller.setPauseOnDeviceChange(val),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),

              // 6. Dynamic Metadata Event Dispatch Toggle
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: StudioColors.cardBackgroundDark,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: StudioColors.cardBorder),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.tag,
                                size: 14,
                                color: controller.metadataEnabled
                                    ? StudioColors.accentAmber
                                    : StudioColors.textMuted,
                              ),
                              const SizedBox(width: 6),
                              const Expanded(
                                child: Text(
                                  'Dynamic Metadata Event Stream',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: StudioColors.textPrimary,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            controller.metadataEnabled
                                ? 'Active: Rust streams live ID3v2/FLAC/Vorbis metadata events'
                                : 'Disabled: zero channel bus saturation until activated',
                            style: const TextStyle(
                              fontSize: 9.5,
                              color: StudioColors.textMuted,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          controller.metadataEnabled ? 'ON' : 'OFF',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: controller.metadataEnabled
                                ? StudioColors.accentAmber
                                : StudioColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Switch(
                          value: controller.metadataEnabled,
                          activeThumbColor: StudioColors.accentAmber,
                          onChanged: (val) => controller.setMetadataEnabled(val),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Small recording control bar directly below transport controls
  Widget _buildRecordingMenu(BuildContext context) {
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
                    color: isRec ? StudioColors.accentRose : StudioColors.accentCyan,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isRec) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: StudioColors.accentRose.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: StudioColors.accentRose, width: 0.8),
                  ),
                  child: Text(
                    _formatDuration(dur),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      color: StudioColors.accentRose,
                    ),
                  ),
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
                  foregroundColor: isRec ? Colors.white : StudioColors.accentRose,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(
                      color: isRec ? StudioColors.accentRose : StudioColors.cardBorder,
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
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
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
                            style: const TextStyle(color: StudioColors.accentEmerald),
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
                            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
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
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.musicMix,
                          child: Text(
                            'Music',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.activeTrack,
                          child: Text(
                            'Active',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.standbyTrack,
                          child: Text(
                            'Cue',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600),
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
  }
}
