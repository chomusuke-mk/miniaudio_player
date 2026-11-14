import 'package:flutter/material.dart';

import '../../controllers/audio_analyzer_controller.dart';
import '../../controllers/audio_engine_controller.dart';
import '../widgets/cards/dsp_effects_card.dart';
import '../widgets/cards/hardware_routing_card.dart';
import '../widgets/cards/playback_engine_card.dart';
import '../widgets/cards/playlist_queue_card.dart';
import '../widgets/cards/ram_sound_effects_card.dart';
import '../widgets/cards/spectrum_visualizer_card.dart';
import '../widgets/common/responsive_grid.dart';

class StudioConsoleView extends StatelessWidget {
  final AudioEngineController playerController;
  final AudioAnalyzerController analyzerController;

  const StudioConsoleView({
    super.key,
    required this.playerController,
    required this.analyzerController,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Row 1: Playing (2), Queue (2), Effects (1) — 2:2:1 responsive proportions
        ResponsiveGrid.multi(
          columns: [
            ResponsiveColumnGroup(
              flex: 2,
              children: [
                RepaintBoundary(
                  child: PlaybackEngineCard(
                    controller: playerController,
                    analyzerController: analyzerController,
                  ),
                ),
              ],
            ),
            ResponsiveColumnGroup(
              flex: 2,
              children: [
                RepaintBoundary(
                  child: PlaylistQueueCard(
                    controller: playerController,
                    analyzerController: analyzerController,
                  ),
                ),
              ],
            ),
            ResponsiveColumnGroup(
              flex: 1,
              children: [
                RepaintBoundary(
                  child: RamSoundEffectsCard(controller: playerController),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Row 2: Hardware Routing + Spectrum Visualizer (1/3) and DSP Effects (2/3)
        ResponsiveGrid(
          leftFlex: 1,
          rightFlex: 2,
          leftColumn: [
            RepaintBoundary(
              child: HardwareRoutingCard(controller: playerController),
            ),
            RepaintBoundary(
              child: SpectrumVisualizerCard(controller: playerController),
            ),
          ],
          rightColumn: [
            RepaintBoundary(
              child: DspEffectsCard(controller: playerController),
            ),
          ],
        ),
      ],
    );
  }
}
