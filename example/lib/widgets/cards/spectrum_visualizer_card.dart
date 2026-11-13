import 'package:flutter/material.dart';
import 'package:miniaudio_player/miniaudio_player.dart';

import '../../controllers/audio_engine_controller.dart';
import '../../theme/studio_colors.dart';
import '../common/studio_badge.dart';
import '../common/studio_card.dart';
import '../painters/spectrum_painter.dart';
import '../painters/vu_meter_painter.dart';

class SpectrumVisualizerCard extends StatelessWidget {
  final AudioEngineController controller;

  const SpectrumVisualizerCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final isEnabled = controller.visualizerEnabled;

          return StudioCard(
            icon: Icons.ssid_chart,
            title: 'Real-Time Reactive Visualizer',
            subtitle:
                '10-Band BPF Filter Bank • Instant RMS & True-Peak Detection',
            trailing: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              runSpacing: 4,
              children: [
                // Audio Source Selector Dropdown (styled identically to recorder and routing matrix)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF070B14),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: StudioColors.cardBorder),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<AudioOutputSource>(
                      value: controller.visualizerSource,
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
                            'Music Only',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.activeTrack,
                          child: Text(
                            'Active Deck',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        DropdownMenuItem(
                          value: AudioOutputSource.standbyTrack,
                          child: Text(
                            'Cue Deck',
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
                      onChanged: isEnabled
                          ? (src) {
                              if (src != null) {
                                controller.setVisualizerSource(src);
                              }
                            }
                          : null,
                    ),
                  ),
                ),
                const StudioBadge(
                  label: '0% Idle CPU',
                  color: StudioColors.accentEmerald,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isEnabled ? 'ON' : 'OFF',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isEnabled
                            ? StudioColors.accentCyan
                            : StudioColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Switch(
                      value: isEnabled,
                      activeThumbColor: StudioColors.accentCyan,
                      onChanged: (val) => controller.setVisualizerEnabled(val),
                    ),
                  ],
                ),
              ],
            ),
            child: AnimatedOpacity(
              opacity: isEnabled ? 1.0 : 0.38,
              duration: const Duration(milliseconds: 250),
              child: IgnorePointer(
                ignoring: !isEnabled,
                child: StreamBuilder<VisualizerData>(
                  stream: controller.engine.stream.visualizer,
                  initialData: controller.engine.state.visualizer,
                  builder: (context, snapshot) {
                    final data = snapshot.data;
                    final bands = data?.bands ?? List.filled(10, 0.0);
                    final left = data?.left ?? 0.0;
                    final right = data?.right ?? 0.0;

                    return LayoutBuilder(
                      builder: (context, constraints) {
                        final height = constraints.maxWidth < 400
                            ? 150.0
                            : 170.0;

                        return SizedBox(
                          height: height,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 10-Band Spectrum Analyzer
                              Expanded(
                                flex: 7,
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: SpectrumPainter(
                                      magnitudes: bands,
                                      isActive: isEnabled,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              // Stereo VU meters (L / R)
                              Expanded(
                                flex: 3,
                                child: RepaintBoundary(
                                  child: CustomPaint(
                                    painter: VuMeterPainter(
                                      leftLevel: left,
                                      rightLevel: right,
                                      isActive: isEnabled,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
