import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';
import '../../controllers/audio_engine_controller.dart';
import '../../models/audio_track.dart';
import '../../theme/studio_colors.dart';
import '../common/compact_slider_overlay.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../painters/waveform_painter.dart';

class PlaybackEngineCard extends StatelessWidget {
  final AudioEngineController controller;

  const PlaybackEngineCard({super.key, required this.controller});

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
      listenable: controller,
      builder: (context, _) {
        final track = controller.selectedTrack;

        return StudioCard(
          icon: Icons.graphic_eq,
          title: 'HIGH-RES AUDIO PLAYBACK ENGINE',
          subtitle: 'Dual-Deck Hardware Threads • Sonic DSP Varispeed',
          trailing: StreamBuilder<EngineItem<AudioTrack>?>(
            stream: engine.stream.currentItem,
            initialData: engine.state.currentItem,
            builder: (context, currentSnap) {
              final activeTrack = currentSnap.data?.data ?? track;
              return StreamBuilder<int>(
                stream: engine.stream.bitrate,
                initialData: engine.state.bitrate,
                builder: (context, snapshot) {
                  return StudioBadge(
                    label: TrackFormatInfo.deduceFormatBadge(
                      activeTrack,
                      bitrate: snapshot.data ?? 0,
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
              // 1. Current Track Display (No dropdown, clean active track banner)
              StreamBuilder<EngineItem<AudioTrack>?>(
                stream: engine.stream.currentItem,
                initialData: engine.state.currentItem,
                builder: (context, currentSnap) {
                  final activeTrack = currentSnap.data?.data ?? track;
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0F1D),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: StudioColors.cardBorder, width: 1.0),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          activeTrack?.icon ?? Icons.audiotrack,
                          color: activeTrack?.iconColor ?? StudioColors.accentCyan,
                          size: 22,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                activeTrack?.title ?? 'Sin pista seleccionada',
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
                                activeTrack != null
                                    ? '${activeTrack.artist ?? "Desconocido"} • ${activeTrack.displayType}'
                                    : 'Selecciona una pista en la cola',
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
                        const SizedBox(width: 6),
                        StudioBadge(
                          label: activeTrack?.resourceBadge ?? 'VACÍO',
                          color: activeTrack?.iconColor ?? StudioColors.accentCyan,
                        ),
                      ],
                    ),
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
                  final progress = (dur.inMilliseconds > 0)
                      ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
                      : 0.0;

                  return StreamBuilder<Duration>(
                    stream: engine.stream.bufferedPosition,
                    initialData: engine.state.bufferedPosition,
                    builder: (context, bufSnap) {
                      final bufPos = bufSnap.data ?? engine.state.bufferedPosition;
                      final isLocal = track?.source is AssetAudioSource ||
                          track?.source is MemoryAudioSource ||
                          track?.source is FileAudioSource;
                      final bufferedProgress = isLocal
                          ? 1.0
                          : (dur.inMilliseconds > 0
                              ? (bufPos.inMilliseconds / dur.inMilliseconds)
                                  .clamp(0.0, 1.0)
                              : engine.state.bufferedPercentage.clamp(0.0, 1.0));

                      return Column(
                        children: [
                          LayoutBuilder(
                            builder: (ctx, constraints) {
                              return GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) {
                                  final frac = details.localPosition.dx /
                                      constraints.maxWidth;
                                  _seekToFraction(context, frac, dur);
                                },
                                onHorizontalDragStart: (details) {
                                  final frac = details.localPosition.dx /
                                      constraints.maxWidth;
                                  _seekToFraction(context, frac, dur);
                                },
                                onHorizontalDragUpdate: (details) {
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
                                  _formatDuration(dur),
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
              ),
              const SizedBox(height: 8),

              // 3. Playback Controls Row: Left (Transport) & Right (Vol, Speed, Pitch Overlays)
              LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 460;

                  // Left Controls: prev, play/pause, next, stop, random, loop
                  final leftControls = StreamBuilder<PlaybackState>(
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
                            tooltip: 'Anterior',
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
                            tooltip: isPlaying ? 'Pausar' : 'Reproducir',
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
                            tooltip: 'Siguiente',
                            onPressed: controller.nextTrack,
                          ),
                          IconButton(
                            icon: const Icon(Icons.stop, size: 20),
                            color: StudioColors.accentRose,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Detener',
                            onPressed: engine.action.stop,
                          ),
                          IconButton(
                            icon: const Icon(Icons.shuffle, size: 18),
                            color: controller.isShuffle
                                ? StudioColors.accentCyan
                                : StudioColors.textMuted,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Aleatorio',
                            onPressed: controller.toggleShuffle,
                          ),
                          IconButton(
                            icon: Icon(
                              controller.isLoop ? Icons.repeat_one : Icons.repeat,
                              size: 18,
                            ),
                            color: controller.isLoop
                                ? StudioColors.accentCyan
                                : StudioColors.textMuted,
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Repetir',
                            onPressed: controller.toggleLoop,
                          ),
                        ],
                      );
                    },
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

              // 4. Hardware Routing: Buffer Size & Audio Output Device
              LayoutBuilder(
                builder: (context, constraints) {
                  final stackHardware = constraints.maxWidth < 360;
                  final bufferDropdown = DropdownButtonFormField<int>(
                    initialValue: controller.selectedBufferSize,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Hardware Buffer',
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
                  );

                  final deviceDropdown = DropdownButtonFormField<AudioDevice>(
                    initialValue: controller.selectedDevice,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Dispositivo de Salida',
                      prefixIcon: Icon(Icons.headphones, size: 16),
                      contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    ),
                    items: controller.audioDevices.map((dev) {
                      return DropdownMenuItem<AudioDevice>(
                        value: dev,
                        child: Text(
                          dev.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 10.5),
                        ),
                      );
                    }).toList(),
                    onChanged: (dev) {
                      if (dev != null) controller.setDevice(dev);
                    },
                  );

                  if (stackHardware) {
                    return Column(
                      children: [
                        bufferDropdown,
                        const SizedBox(height: 8),
                        deviceDropdown,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: bufferDropdown),
                      const SizedBox(width: 8),
                      Expanded(child: deviceDropdown),
                    ],
                  );
                },
              ),
              const SizedBox(height: 10),
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
                                  'Pausar al cambiar de salida',
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
                                ? 'Pausa nativa inmediata (0ms leak) si el endpoint físico cambia'
                                : 'Inactivo: audio conmuta al nuevo endpoint sin pausar',
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
            ],
          ),
        );
      },
    );
  }
}
